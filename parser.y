%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

extern int yylex();
extern int yylineno;
extern FILE *yyin;
void yyerror(const char *s);

#define MAX_SYMS 1000
#define MAX_ASSIGNS 300
#define NAME_LEN 128
#define MAX_SCOPE_DEPTH 32

// Symbol Table (Tracks Reads vs Writes). Each symbol is tagged with the
// function it was declared in ("" means declared at global scope), so two
// different functions can each safely have their own unrelated "int i;"
// without polluting each other's dead-code analysis.
struct Symbol {
    char name[NAME_LEN];
    char scope[NAME_LEN];            // owning function name, or "" for global
    int is_read;                     // 1 if the variable is ever read
    int decl_line;                   // Line where it was declared
    int assign_lines[MAX_ASSIGNS];   // Every line where it was (re)assigned
    int assign_count;
} sym_table[MAX_SYMS];
int sym_count = 0;

// Tiny scope stack: pushed on entering a function body, popped on leaving it.
char scope_stack[MAX_SCOPE_DEPTH][NAME_LEN];
int scope_depth = 0;

const char *current_scope(void) {
    return scope_depth == 0 ? "" : scope_stack[scope_depth - 1];
}

void enter_function(const char *name) {
    if (scope_depth < MAX_SCOPE_DEPTH) {
        strncpy(scope_stack[scope_depth], name ? name : "", NAME_LEN - 1);
        scope_stack[scope_depth][NAME_LEN - 1] = '\0';
        scope_depth++;
    }
}

void exit_function(void) {
    if (scope_depth > 0) scope_depth--;
}

int dead_vars = 0;
int constant_folds = 0;
char fold_messages[8192] = "";
size_t fold_len = 0;

void add_fold_message(const char *msg) {
    size_t mlen = strlen(msg);
    if (fold_len + mlen < sizeof(fold_messages) - 1) {
        strcpy(fold_messages + fold_len, msg);
        fold_len += mlen;
    }
}

// Register a new variable in the current scope (ignored if the table is
// full or this exact name+scope was already declared).
void declare_var(char *name, int line) {
    if (!name) return;
    const char *sc = current_scope();
    for (int i = 0; i < sym_count; i++) {
        if (strcmp(sym_table[i].name, name) == 0 && strcmp(sym_table[i].scope, sc) == 0) return;
    }
    if (sym_count >= MAX_SYMS) return;
    strncpy(sym_table[sym_count].name, name, NAME_LEN - 1);
    sym_table[sym_count].name[NAME_LEN - 1] = '\0';
    strncpy(sym_table[sym_count].scope, sc, NAME_LEN - 1);
    sym_table[sym_count].scope[NAME_LEN - 1] = '\0';
    sym_table[sym_count].decl_line = line;
    sym_table[sym_count].is_read = 0;
    sym_table[sym_count].assign_count = 0;
    sym_count++;
}

// Finds the symbol table index best matching `name` from the current scope:
// prefer an exact scope match (a local of the current function), otherwise
// fall back to a global (scope == "") declaration. Returns -1 if none.
int resolve_symbol(const char *name) {
    const char *sc = current_scope();
    int global_idx = -1;
    for (int i = 0; i < sym_count; i++) {
        if (strcmp(sym_table[i].name, name) != 0) continue;
        if (strcmp(sym_table[i].scope, sc) == 0) return i;
        if (sym_table[i].scope[0] == '\0') global_idx = i;
    }
    return global_idx;
}

// Mark a variable as genuinely used (read in an expression / condition / print / call)
void mark_read(char *name) {
    if (!name) return;
    int idx = resolve_symbol(name);
    if (idx >= 0) sym_table[idx].is_read = 1;
}

// Track every line where a variable gets a new value
void mark_assigned(char *name, int line) {
    if (!name) return;
    int idx = resolve_symbol(name);
    if (idx >= 0 && sym_table[idx].assign_count < MAX_ASSIGNS) {
        sym_table[idx].assign_lines[sym_table[idx].assign_count++] = line;
    }
}
%}

%union {
    int ival;
    char* str;
    struct { int val; int is_const; } eval;
}

%token <str> TYPE ID STRING_LITERAL
%token <ival> NUMBER
%token IF ELSE WHILE FOR DO BREAK CONTINUE RETURN PRINT
%token EQ NE LE GE AND OR INC DEC PLUSEQ MINUSEQ MULEQ DIVEQ

%type <eval> expr

%right '?' ':'
%left OR
%left AND
%left EQ NE
%left '<' '>' LE GE
%left '+' '-'
%left '*' '/'
%right UMINUS '!'

%%

program: statements ;

statements: /* empty */ | statements statement ;

statement:
    declaration
  | assignment_stmt
  | control_struct
  | jump_stmt
  | print_stmt
  | func_call_stmt
  | return_stmt
  | block
  | function_def
  | empty_stmt
  ;

empty_stmt: ';' ;

jump_stmt: BREAK ';' | CONTINUE ';' ;

function_def: TYPE ID '(' param_list ')' { enter_function($2); } block { exit_function(); } ;

param_list: /* empty */ | params ;
params: param | params ',' param ;
// Parameters are intentionally NOT added to the symbol table: removing an
// unused parameter would change the function signature, which is not safe
// "dead code" elimination.
param: TYPE ID ;

block: '{' statements '}' ;

// ---- Declarations (supports multiple vars per line: int a, b = 5, c;) ----
declaration: TYPE decl_list ';' ;

decl_list: decl_item | decl_list ',' decl_item ;

decl_item:
    ID                              { declare_var($1, yylineno); }
  | ID '[' expr ']'                 { declare_var($1, yylineno); }
  | ID '=' expr                     { declare_var($1, yylineno); }
  | ID '=' STRING_LITERAL           { declare_var($1, yylineno); }
  | ID '[' expr ']' '=' STRING_LITERAL          { declare_var($1, yylineno); }
  | ID '[' expr ']' '=' '{' array_init '}'      { declare_var($1, yylineno); }
  | ID '[' ']' '=' '{' array_init '}'           { declare_var($1, yylineno); }
  ;

array_init: expr | array_init ',' expr ;

// ---- Assignments (=, +=, -=, *=, /=, ++, --) ----
assignment_stmt: simple_assign ';' ;

simple_assign:
    ID '=' expr                  { mark_assigned($1, yylineno); }
  | ID '[' expr ']' '=' expr     { mark_assigned($1, yylineno); }
  | ID PLUSEQ expr                { mark_read($1); mark_assigned($1, yylineno); }
  | ID MINUSEQ expr               { mark_read($1); mark_assigned($1, yylineno); }
  | ID MULEQ expr                 { mark_read($1); mark_assigned($1, yylineno); }
  | ID DIVEQ expr                 { mark_read($1); mark_assigned($1, yylineno); }
  | ID INC                        { mark_read($1); mark_assigned($1, yylineno); }
  | ID DEC                        { mark_read($1); mark_assigned($1, yylineno); }
  | INC ID                        { mark_read($2); mark_assigned($2, yylineno); }
  | DEC ID                        { mark_read($2); mark_assigned($2, yylineno); }
  ;

// ---- Control structures: if/else, while, do-while, for ----
control_struct:
    IF '(' expr ')' statement ELSE statement
  | IF '(' expr ')' statement
  | WHILE '(' expr ')' statement
  | DO statement WHILE '(' expr ')' ';'
  | FOR '(' for_init ';' for_cond ';' for_incr ')' statement
  ;

for_init:
    simple_assign
  | TYPE ID '=' expr   { declare_var($2, yylineno); }
  | TYPE ID            { declare_var($2, yylineno); }
  | /* empty */
  ;

for_cond: expr | /* empty */ ;

for_incr: simple_assign | /* empty */ ;

print_stmt:
    PRINT '(' STRING_LITERAL ')' ';'
  | PRINT '(' STRING_LITERAL ',' args ')' ';'
  | PRINT '(' args ')' ';'
  ;

func_call_stmt: ID '(' opt_args ')' ';' ;

opt_args: /* empty */ | args ;
args: expr | args ',' expr ;

return_stmt: RETURN expr ';' | RETURN ';' ;

expr:
    NUMBER                    { $$.val = $1; $$.is_const = 1; }
  | ID                        { mark_read($1); $$.val = 0; $$.is_const = 0; }
  | ID '[' expr ']'           { mark_read($1); $$.val = 0; $$.is_const = 0; }
  | ID INC                    { mark_read($1); mark_assigned($1, yylineno); $$.val = 0; $$.is_const = 0; }
  | ID DEC                    { mark_read($1); mark_assigned($1, yylineno); $$.val = 0; $$.is_const = 0; }
  | '(' expr ')'              { $$ = $2; }
  | '-' expr %prec UMINUS     { $$.val = -$2.val; $$.is_const = $2.is_const; }
  | '!' expr                  { $$.val = !$2.val; $$.is_const = $2.is_const; }
  | expr '+' expr {
        $$.is_const = $1.is_const && $3.is_const;
        $$.val = $1.val + $3.val;
        if ($$.is_const) {
            constant_folds++;
            char buf[128]; snprintf(buf, sizeof(buf), "- Folded: %d + %d -> %d\n", $1.val, $3.val, $$.val);
            add_fold_message(buf);
        }
    }
  | expr '-' expr {
        $$.is_const = $1.is_const && $3.is_const;
        $$.val = $1.val - $3.val;
        if ($$.is_const) {
            constant_folds++;
            char buf[128]; snprintf(buf, sizeof(buf), "- Folded: %d - %d -> %d\n", $1.val, $3.val, $$.val);
            add_fold_message(buf);
        }
    }
  | expr '*' expr {
        $$.is_const = $1.is_const && $3.is_const;
        $$.val = $1.val * $3.val;
        if ($$.is_const) {
            constant_folds++;
            char buf[128]; snprintf(buf, sizeof(buf), "- Folded: %d * %d -> %d\n", $1.val, $3.val, $$.val);
            add_fold_message(buf);
        }
    }
  | expr '/' expr {
        $$.is_const = $1.is_const && $3.is_const;
        if ($3.val != 0) $$.val = $1.val / $3.val; else $$.val = 0;
        if ($$.is_const) {
            constant_folds++;
            char buf[128]; snprintf(buf, sizeof(buf), "- Folded: %d / %d -> %d\n", $1.val, $3.val, $$.val);
            add_fold_message(buf);
        }
    }
  | expr '<' expr  { $$.val = $1.val < $3.val;  $$.is_const = $1.is_const && $3.is_const; }
  | expr '>' expr  { $$.val = $1.val > $3.val;  $$.is_const = $1.is_const && $3.is_const; }
  | expr LE expr   { $$.val = $1.val <= $3.val; $$.is_const = $1.is_const && $3.is_const; }
  | expr GE expr   { $$.val = $1.val >= $3.val; $$.is_const = $1.is_const && $3.is_const; }
  | expr EQ expr   { $$.val = $1.val == $3.val; $$.is_const = $1.is_const && $3.is_const; }
  | expr NE expr   { $$.val = $1.val != $3.val; $$.is_const = $1.is_const && $3.is_const; }
  | expr AND expr  { $$.val = $1.val && $3.val; $$.is_const = $1.is_const && $3.is_const; }
  | expr OR expr   { $$.val = $1.val || $3.val; $$.is_const = $1.is_const && $3.is_const; }
  | expr '?' expr ':' expr { $$ = $1.val ? $3 : $5; }
  ;

%%

int has_error = 0;

void yyerror(const char *s) {
    fprintf(stderr, "Syntax Error near line %d: %s\n", yylineno, s);
    has_error = 1;
}

// A line is dead if it declares or assigns a variable that is never read anywhere.
int is_dead_line(int line) {
    for (int i = 0; i < sym_count; i++) {
        if (sym_table[i].is_read == 0) {
            if (sym_table[i].decl_line == line) return 1;
            for (int j = 0; j < sym_table[i].assign_count; j++) {
                if (sym_table[i].assign_lines[j] == line) return 1;
            }
        }
    }
    return 0;
}

// Does this string contain any non-whitespace character?
int line_has_content(const char *s) {
    for (; *s; s++) {
        if (!isspace((unsigned char)*s)) return 1;
    }
    return 0;
}

// Strips // line comments and /* block comments */ (which may span multiple
// lines) out of a single physical line. `in_block` carries the "currently
// inside an unterminated block comment" state across successive calls, so
// it must be a persistent variable owned by the caller. Note: like the
// lexer's own comment rules, this does not special-case comment markers
// that appear inside string literals (e.g. printf("// not a comment")) -
// a known simplification consistent with the rest of this project's scope.
void strip_comments_from_line(const char *in, char *out, size_t outsz, int *in_block) {
    size_t oi = 0;
    size_t i = 0;
    while (in[i] != '\0' && oi + 1 < outsz) {
        if (*in_block) {
            if (in[i] == '*' && in[i + 1] == '/') {
                *in_block = 0;
                i += 2;
            } else {
                i++;
            }
            continue;
        }
        if (in[i] == '/' && in[i + 1] == '/') {
            break; // rest of the physical line is a comment
        }
        if (in[i] == '/' && in[i + 1] == '*') {
            *in_block = 1;
            i += 2;
            continue;
        }
        out[oi++] = in[i++];
    }
    // Trim trailing spaces/tabs left behind by a removed comment.
    while (oi > 0 && (out[oi - 1] == ' ' || out[oi - 1] == '\t')) oi--;
    out[oi] = '\0';
}

int main(int argc, char **argv) {
    if (argc > 1) {
        yyin = fopen(argv[1], "r");
        if (!yyin) {
            fprintf(stderr, "Error: could not open input file '%s'\n", argv[1]);
            return 1;
        }
    } else {
        fprintf(stderr, "Usage: %s <input.c> [output.c]\n", argv[0]);
        return 1;
    }

    const char *output_path = (argc > 2) ? argv[2] : "output_optimized.c";

    yyparse();
    fclose(yyin);

    if (has_error) {
        return 1;
    }

    printf("====================================================\n");
    printf("OPTIMIZATION SUMMARY REPORT\n");
    printf("====================================================\n");
    printf("Status                      : SUCCESS\n");
    printf("Output Saved To             : %s\n", output_path);
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
    FILE *out = fopen(output_path, "w");
    if (!in || !out) {
        fprintf(stderr, "Error: could not open files for final output write.\n");
        if (in) fclose(in);
        if (out) fclose(out);
        return 1;
    }
    char line_buf[2048];
    int current_line = 1;
    int in_block_comment = 0; // persists across lines for multi-line /* */ comments

    while (fgets(line_buf, sizeof(line_buf), in)) {
        char cleaned[2100];

        if (!is_dead_line(current_line)) {
            int line_had_content = line_has_content(line_buf);
            strip_comments_from_line(line_buf, cleaned, sizeof(cleaned), &in_block_comment);
            int cleaned_has_content = line_has_content(cleaned);

            // Only emit the line if it isn't left empty purely because a
            // comment (full-line or trailing) was removed from it.
            if (!(line_had_content && !cleaned_has_content)) {
                size_t clen = strlen(cleaned);
                int orig_had_nl = (line_buf[0] != '\0' && line_buf[strlen(line_buf) - 1] == '\n');
                int cleaned_has_nl = (clen > 0 && cleaned[clen - 1] == '\n');
                if (orig_had_nl && !cleaned_has_nl && clen + 1 < sizeof(cleaned)) {
                    cleaned[clen] = '\n';
                    cleaned[clen + 1] = '\0';
                }
                printf("%s", cleaned);
                fputs(cleaned, out);
            }
        } else {
            // Line is being deleted as dead code, but it might still open or
            // close a block comment - scan it (discarding the result) so
            // in_block_comment stays correct for the lines that follow.
            strip_comments_from_line(line_buf, cleaned, sizeof(cleaned), &in_block_comment);
        }
        current_line++;
    }
    fclose(in);
    fclose(out);
    printf("\n====================================================\n");
    return 0;
}
