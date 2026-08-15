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
#define MAX_EVENTS 500
#define NAME_LEN 128
#define MAX_SCOPE_DEPTH 32

// Symbol Table (Tracks Reads vs Writes). Each symbol is tagged with the
// function it was declared in ("" means declared at global scope), so two
// different functions can each safely have their own unrelated "int i;"
// without polluting each other's dead-code analysis.
//
// Every read and write is also logged, in source order, as an "event". This
// powers dead-store detection: a write is dead if it's overwritten by
// another write before ever being read. Array-element writes (arr[i] = x)
// are logged but marked ineligible for this check, since this tool tracks
// whole arrays as one symbol and can't safely tell whether two different
// indices alias each other.
struct Symbol {
    char name[NAME_LEN];
    char scope[NAME_LEN];            // owning function name, or "" for global
    int is_read;                     // 1 if the variable is ever read anywhere
    int decl_line;                   // Line where it was declared
    struct { int line; int is_write; int eligible; } events[MAX_EVENTS];
    int event_count;
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

// ---- Function table (unused-function detection) ----
#define MAX_FUNCS 200

struct FuncInfo {
    char name[NAME_LEN];
    int start_line;   // line of the return-type keyword
    int end_line;      // line of the closing '}'
    int is_called;
} func_table[MAX_FUNCS];
int func_count = 0;

void register_function(const char *name, int start_line, int end_line) {
    if (!name || func_count >= MAX_FUNCS) return;
    strncpy(func_table[func_count].name, name, NAME_LEN - 1);
    func_table[func_count].name[NAME_LEN - 1] = '\0';
    func_table[func_count].start_line = start_line;
    func_table[func_count].end_line = end_line;
    func_table[func_count].is_called = 0;
    func_count++;
}

void mark_function_called(const char *name) {
    if (!name) return;
    for (int i = 0; i < func_count; i++) {
        if (strcmp(func_table[i].name, name) == 0) {
            func_table[i].is_called = 1;
            return;
        }
    }
}

// ---- Reachability tracking (unreachable-code-after-return/break/continue,
// and dead branches from constant if/while/for conditions) ----
#define MAX_BLOCK_DEPTH 64
#define MAX_UNREACHABLE 2000

struct BlockFrame {
    int terminated;         // has an unconditional return/break/continue already occurred directly in this block?
    int terminated_line;    // the line of that statement
    int saved_cond_depth;   // cond_depth to restore when this block closes
};
struct BlockFrame block_frames[MAX_BLOCK_DEPTH];
int block_depth = 0;

// >0 while parsing the brace-less single-statement body of an if/while/for/do
// (i.e. a statement that only conditionally executes). A `return`/`break`/
// `continue` seen while this is >0 does NOT make later code in the enclosing
// block unreachable, since it might not actually run.
int cond_depth = 0;

struct { int start; int end; } unreachable_ranges[MAX_UNREACHABLE];
int unreachable_count = 0;

void mark_unreachable(int start, int end) {
    if (start > end) return;
    if (unreachable_count < MAX_UNREACHABLE) {
        unreachable_ranges[unreachable_count].start = start;
        unreachable_ranges[unreachable_count].end = end;
        unreachable_count++;
    }
}

int is_unreachable_line(int line) {
    for (int i = 0; i < unreachable_count; i++) {
        if (line >= unreachable_ranges[i].start && line <= unreachable_ranges[i].end) return 1;
    }
    return 0;
}

void cond_enter(void) { cond_depth++; }
void cond_exit(void) { if (cond_depth > 0) cond_depth--; }

void push_block_frame(void) {
    if (block_depth < MAX_BLOCK_DEPTH) {
        block_frames[block_depth].terminated = 0;
        block_frames[block_depth].terminated_line = -1;
        block_frames[block_depth].saved_cond_depth = cond_depth;
        cond_depth = 0; // fresh block: statements in it run sequentially/unconditionally by default
        block_depth++;
    }
}

void pop_block_frame(int close_line) {
    if (block_depth <= 0) return;
    block_depth--;
    struct BlockFrame *f = &block_frames[block_depth];
    if (f->terminated) {
        mark_unreachable(f->terminated_line + 1, close_line - 1);
    }
    cond_depth = f->saved_cond_depth;
}

// Only an unconditional, direct-in-block return/break/continue counts
// (cond_depth == 0); one nested inside a brace-less if/while/for body might
// not execute. All three have the same effect on straight-line reachability
// within the immediately enclosing block: nothing after them in that block
// runs.
void mark_frame_terminated(int line) {
    if (block_depth <= 0 || cond_depth != 0) return;
    struct BlockFrame *f = &block_frames[block_depth - 1];
    if (!f->terminated) {
        f->terminated = 1;
        f->terminated_line = line;
    }
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
    sym_table[sym_count].event_count = 0;
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

void append_event(int idx, int line, int is_write, int eligible) {
    if (idx < 0) return;
    if (sym_table[idx].event_count < MAX_EVENTS) {
        int e = sym_table[idx].event_count++;
        sym_table[idx].events[e].line = line;
        sym_table[idx].events[e].is_write = is_write;
        sym_table[idx].events[e].eligible = eligible;
    }
}

// Mark a variable as genuinely used (read in an expression / condition / print / call)
void mark_read(char *name) {
    if (!name) return;
    int idx = resolve_symbol(name);
    if (idx < 0) return;
    sym_table[idx].is_read = 1;
    append_event(idx, yylineno, 0, 1);
}

// Track every line where a scalar variable gets a new value (eligible for
// dead-store analysis).
void mark_assigned(char *name, int line) {
    if (!name) return;
    int idx = resolve_symbol(name);
    append_event(idx, line, 1, 1);
}

// Same, but for an array-element write (arr[i] = x); excluded from dead-store
// analysis since different indices don't actually overwrite each other.
void mark_assigned_array(char *name, int line) {
    if (!name) return;
    int idx = resolve_symbol(name);
    append_event(idx, line, 1, 0);
}
%}

%union {
    int ival;
    char* str;
    struct { int val; int is_const; } eval;
    struct { int open; int close; } range;
}

%token <str> TYPE ID STRING_LITERAL
%token <ival> NUMBER
%token IF ELSE WHILE FOR DO BREAK CONTINUE RETURN PRINT
%token EQ NE LE GE AND OR INC DEC PLUSEQ MINUSEQ MULEQ DIVEQ

%type <eval> expr for_cond
%type <range> statement block

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
    declaration      { $$.open = 0; $$.close = 0; }
  | assignment_stmt   { $$.open = 0; $$.close = 0; }
  | control_struct    { $$.open = 0; $$.close = 0; }
  | jump_stmt         { $$.open = 0; $$.close = 0; }
  | print_stmt        { $$.open = 0; $$.close = 0; }
  | func_call_stmt     { $$.open = 0; $$.close = 0; }
  | return_stmt        { $$.open = 0; $$.close = 0; }
  | block               { $$ = $1; }
  | function_def         { $$.open = 0; $$.close = 0; }
  | empty_stmt            { $$.open = 0; $$.close = 0; }
  ;

empty_stmt: ';' ;

jump_stmt: BREAK ';' { mark_frame_terminated(yylineno); } | CONTINUE ';' { mark_frame_terminated(yylineno); } ;

function_def: TYPE { $<ival>$ = yylineno; } ID '(' param_list ')' { enter_function($3); } block { exit_function(); register_function($3, $<ival>2, $8.close); } ;

param_list: /* empty */ | params ;
params: param | params ',' param ;
// Parameters are intentionally NOT added to the symbol table: removing an
// unused parameter would change the function signature, which is not safe
// "dead code" elimination.
param: TYPE ID ;

block: '{' { push_block_frame(); $<ival>$ = yylineno; } statements '}'
       {
           int open_line = $<ival>2;
           int close_line = yylineno;
           pop_block_frame(close_line);
           $$.open = open_line;
           $$.close = close_line;
       }
     ;

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
  | ID '[' expr ']' '=' expr     { mark_assigned_array($1, yylineno); }
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
// Brace-less single-statement bodies are wrapped with cond_enter/cond_exit
// so a `return` inside them is correctly treated as conditional (it might
// not execute), not as making the rest of the enclosing block unreachable.
//
// Constant-condition dead-branch elimination only applies when the affected
// branch is written as an explicit { } block: that lets us safely blank out
// just its interior lines (never the header or the braces themselves, which
// may be shared with other syntax like "} else {"), so the output always
// stays valid, compilable C.
control_struct:
    IF { $<ival>$ = yylineno; } '(' expr ')' { cond_enter(); } statement { cond_exit(); }
    ELSE { cond_enter(); } statement { cond_exit(); }
      {
          if ($4.is_const) {
              if ($4.val != 0) {
                  if ($11.open != 0) mark_unreachable($11.open + 1, $11.close - 1);
              } else {
                  if ($7.open != 0) mark_unreachable($7.open + 1, $7.close - 1);
              }
          }
      }
  | IF { $<ival>$ = yylineno; } '(' expr ')' { cond_enter(); } statement { cond_exit(); }
      {
          if ($4.is_const && $4.val == 0 && $7.open != 0) {
              // No else clause, so the whole statement is safely removable.
              mark_unreachable($<ival>2, $7.close);
          }
      }
  | WHILE { $<ival>$ = yylineno; } '(' expr ')' { cond_enter(); } statement { cond_exit(); }
      {
          if ($4.is_const && $4.val == 0 && $7.open != 0) {
              mark_unreachable($<ival>2, $7.close);
          }
      }
  | DO { cond_enter(); } statement { cond_exit(); } WHILE '(' expr ')' ';'
  | FOR { $<ival>$ = yylineno; } '(' for_init ';' for_cond ';' for_incr ')' { cond_enter(); } statement { cond_exit(); }
      {
          if ($6.is_const && $6.val == 0 && $11.open != 0) {
              mark_unreachable($<ival>2, $11.close);
          }
      }
  ;

for_init:
    simple_assign
  | TYPE ID '=' expr   { declare_var($2, yylineno); }
  | TYPE ID            { declare_var($2, yylineno); }
  | /* empty */
  ;

for_cond:
    expr             { $$ = $1; }
  | /* empty */       { $$.is_const = 0; $$.val = 1; } // no condition == always true, matches `for(;;)`
  ;

for_incr: simple_assign | /* empty */ ;

print_stmt:
    PRINT '(' STRING_LITERAL ')' ';'
  | PRINT '(' STRING_LITERAL ',' args ')' ';'
  | PRINT '(' args ')' ';'
  ;

func_call_stmt: ID '(' opt_args ')' ';' { mark_function_called($1); } ;

opt_args: /* empty */ | args ;
args: expr | args ',' expr ;

return_stmt: RETURN expr ';' { mark_frame_terminated(yylineno); } | RETURN ';' { mark_frame_terminated(yylineno); } ;

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
            for (int j = 0; j < sym_table[i].event_count; j++) {
                if (sym_table[i].events[j].is_write && sym_table[i].events[j].line == line) return 1;
            }
        }
    }
    return 0;
}

// ---- Dead-store detection ----
// A write is a "dead store" if it gets overwritten by another write to the
// same variable before that value is ever read. This walks each symbol's
// event list (source order) once. Only runs for variables that ARE read
// somewhere overall (sym_table[i].is_read == 1) - a variable that's never
// read at all is already fully removed via is_dead_line, and re-flagging its
// writes here would just be redundant. Array-element writes are skipped,
// since this tool can't tell whether two different indices alias.
//
// Known limitation: this is source-order, not true control-flow order, so
// it can misjudge writes inside loops/branches relative to code after them.
// It's a heuristic, like the rest of this tool's analyses.
#define MAX_DEAD_STORES 1000
int dead_store_lines[MAX_DEAD_STORES];
int dead_store_count = 0;

void compute_dead_stores(void) {
    for (int i = 0; i < sym_count; i++) {
        if (!sym_table[i].is_read) continue;
        for (int j = 0; j < sym_table[i].event_count; j++) {
            if (!sym_table[i].events[j].is_write || !sym_table[i].events[j].eligible) continue;
            int dead = 0;
            for (int k = j + 1; k < sym_table[i].event_count; k++) {
                if (!sym_table[i].events[k].eligible) continue; // array writes are invisible to this check
                if (sym_table[i].events[k].is_write) { dead = 1; } else { dead = 0; }
                break;
            }
            if (dead && dead_store_count < MAX_DEAD_STORES) {
                dead_store_lines[dead_store_count++] = sym_table[i].events[j].line;
            }
        }
    }
}

int is_dead_store_line(int line) {
    for (int i = 0; i < dead_store_count; i++) {
        if (dead_store_lines[i] == line) return 1;
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

    compute_dead_stores();

    // Any function that's never called (except main, which the C runtime
    // calls implicitly) is dead code: blank out its entire definition.
    int dead_func_count = 0;
    for (int i = 0; i < func_count; i++) {
        if (!func_table[i].is_called && strcmp(func_table[i].name, "main") != 0) {
            mark_unreachable(func_table[i].start_line, func_table[i].end_line);
            dead_func_count++;
        }
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
    printf("Dead Stores Removed         : %d (value overwritten before use)\n", dead_store_count);
    printf("Dead Functions Removed      : %d (never called)\n", dead_func_count);
    printf("Unreachable Code Segments   : %d (dead branches / code after return, break, continue)\n", unreachable_count);
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
    if (dead_store_count > 0) {
        printf("\nDead Stores Eliminated :\n");
        for (int i = 0; i < dead_store_count; i++) {
            printf("- Line %d (value overwritten before being read)\n", dead_store_lines[i]);
        }
    }
    if (dead_func_count > 0) {
        printf("\nDead Functions Eliminated :\n");
        for (int i = 0; i < func_count; i++) {
            if (!func_table[i].is_called && strcmp(func_table[i].name, "main") != 0) {
                printf("- Removed Function '%s' (Never Called)\n", func_table[i].name);
            }
        }
    }
    if (unreachable_count > 0) {
        printf("\nUnreachable Code Eliminated :\n");
        for (int i = 0; i < unreachable_count; i++) {
            if (unreachable_ranges[i].start == unreachable_ranges[i].end) {
                printf("- Line %d (unreachable / dead-condition branch)\n", unreachable_ranges[i].start);
            } else {
                printf("- Lines %d-%d (unreachable / dead-condition branch)\n", unreachable_ranges[i].start, unreachable_ranges[i].end);
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
        int line_is_dead = is_dead_line(current_line) || is_unreachable_line(current_line) || is_dead_store_line(current_line);

        if (!line_is_dead) {
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
