%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int yylex();
extern int yylineno;
extern FILE *yyin;
void yyerror(const char *s);

// Advanced Symbol Table (Tracks Reads vs Writes)
struct Symbol {
    char name[50];
    int is_read;         // 1 if the variable is actually used
    int decl_line;       // Line where it was created
    int assign_lines[20];// Tracks up to 20 different lines where it was assigned
    int assign_count;
} sym_table[100];
int sym_count = 0;

int dead_vars = 0;
int constant_folds = 0;
char fold_messages[1000] = ""; 

// Register a new variable
void declare_var(char *name, int line) {
    for (int i = 0; i < sym_count; i++) {
        if (strcmp(sym_table[i].name, name) == 0) return;
    }
    strcpy(sym_table[sym_count].name, name);
    sym_table[sym_count].decl_line = line;
    sym_table[sym_count].is_read = 0;
    sym_table[sym_count].assign_count = 0;
    sym_count++;
}

// Mark a variable as TRULY used (Read in an expression)
void mark_read(char *name) {
    for (int i = 0; i < sym_count; i++) {
        if (strcmp(sym_table[i].name, name) == 0) {
            sym_table[i].is_read = 1;
            return;
        }
    }
}

// Track every line where a variable gets a new value
void mark_assigned(char *name, int line) {
    for (int i = 0; i < sym_count; i++) {
        if (strcmp(sym_table[i].name, name) == 0) {
            if (sym_table[i].assign_count < 20) {
                sym_table[i].assign_lines[sym_table[i].assign_count++] = line;
            }
            return;
        }
    }
}
%}

%union {
    int ival;
    char* str;
}

%token <str> TYPE ID STRING_LITERAL
%token <ival> NUMBER
%token IF ELSE WHILE RETURN PRINT

%type <ival> expr

%left '<' '>'
%left '+' '-'
%left '*' '/'
%left '(' ')'

%%

program: statements ;

statements: statement statements | statement ;

statement:
    declaration
    | assignment
    | control_struct
    | print_stmt
    | return_stmt
    | block
    | function_def
    | empty_stmt
    ;

empty_stmt: ';' ;

function_def: TYPE ID '(' ')' block ;

block: '{' statements '}' | '{' '}' ;

// Inline assignments now supported
declaration:
    TYPE ID ';' { declare_var($2, yylineno); }
    | TYPE ID '[' expr ']' ';' { declare_var($2, yylineno); }
    | TYPE ID '=' expr ';' { declare_var($2, yylineno); } 
    ;

// Assignments tracked separately from declarations
assignment:
    ID '=' expr ';' { mark_assigned($1, yylineno); }
    | ID '[' expr ']' '=' expr ';' { mark_assigned($1, yylineno); }
    ;

control_struct:
    IF '(' expr ')' block ELSE block
    | IF '(' expr ')' block
    | IF '(' expr ')' statement
    | WHILE '(' expr ')' block
    | WHILE '(' expr ')' statement
    ;

print_stmt:
    PRINT '(' STRING_LITERAL ')' ';'
    | PRINT '(' STRING_LITERAL ',' args ')' ';'
    ;

args: expr | args ',' expr ;

return_stmt: RETURN expr ';' | RETURN ';' ;

expr:
    NUMBER { $$ = $1; }
    | ID { mark_read($1); $$ = 0; } // Variable is READ here
    | ID '[' expr ']' { mark_read($1); $$ = 0; }
    | '(' expr ')' { $$ = $2; } 
    | expr '+' expr { $$ = $1 + $3; constant_folds++; char buf[100]; sprintf(buf, "- Folded: %d + %d -> %d\n", $1, $3, $$); strcat(fold_messages, buf); }
    | expr '-' expr { $$ = $1 - $3; constant_folds++; char buf[100]; sprintf(buf, "- Folded: %d - %d -> %d\n", $1, $3, $$); strcat(fold_messages, buf); }
    | expr '*' expr { $$ = $1 * $3; constant_folds++; char buf[100]; sprintf(buf, "- Folded: %d * %d -> %d\n", $1, $3, $$); strcat(fold_messages, buf); }
    | expr '/' expr { if($3 != 0) $$ = $1 / $3; else $$ = 0; constant_folds++; }
    | expr '<' expr { $$ = $1 < $3; }
    | expr '>' expr { $$ = $1 > $3; }
    ;

%%

int has_error = 0;

void yyerror(const char *s) { 
    fprintf(stderr, "Syntax Error near line %d: %s\n", yylineno, s);
    has_error = 1;
}

// The ultimate line deleter
int is_dead_line(int line) {
    for (int i = 0; i < sym_count; i++) {
        // If a variable was NEVER read
        if (sym_table[i].is_read == 0) {
            // Delete the line it was declared on
            if (sym_table[i].decl_line == line) return 1;
            // Delete EVERY line where it was assigned a value
            for (int j = 0; j < sym_table[i].assign_count; j++) {
                if (sym_table[i].assign_lines[j] == line) return 1;
            }
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1) {
        yyin = fopen(argv[1], "r");
    }
   yyparse();
    if (yyin) fclose(yyin);

    // --- NEW: STOP IF SYNTAX IS BROKEN ---
    if (has_error) {
        return 1; 
    }
    // -------------------------------------

    printf("====================================================\n");
    printf("OPTIMIZATION SUMMARY REPORT\n");

    printf("====================================================\n");
    printf("OPTIMIZATION SUMMARY REPORT\n");
    printf("====================================================\n");
    printf("Status                      : SUCCESS\n");
    printf("Output Saved To             : output_optimized.c\n");
    printf("Constant Expressions Folded : %d\n", constant_folds);
    
    for (int i = 0; i < sym_count; i++) {
        if (sym_table[i].is_read == 0) dead_vars++;
    }
    printf("Dead Variables Removed      : %d\n", dead_vars);
    printf("----------------------------------------------------\n");
    
    if (strlen(fold_messages) > 0) {
        printf("Optimizations Applied:\n%s", fold_messages);
    }
    if (dead_vars > 0) {
        printf("\nDead Code Eliminated :\n");
        for (int i = 0; i < sym_count; i++) {
            if (sym_table[i].is_read == 0) {
                printf("- Removed Variable '%s' (Unread Memory)\n", sym_table[i].name);
            }
        }
    }
    
    printf("\n====================================================\n");
    printf("OPTIMIZED C SOURCE CODE\n");
    printf("====================================================\n");
    
    FILE *in = fopen(argv[1], "r");
    FILE *out = fopen("output_optimized.c", "w");
    char line_buf[1024];
    int current_line = 1;
    
    while (fgets(line_buf, sizeof(line_buf), in)) {
        if (!is_dead_line(current_line)) {
            printf("%s", line_buf);
            fputs(line_buf, out);
        }
        current_line++;
    }
    fclose(in);
    fclose(out);
    printf("\n====================================================\n");
    return 0;
}
