%{
#include "parser.tab.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
extern int yylineno;
%}

%option noyywrap
%option yylineno

%%

"int"|"float"|"char"|"void" { yylval.str = strdup(yytext); return TYPE; }
"if"                        { return IF; }
"else"                      { return ELSE; }
"while"                     { return WHILE; }
"return"                    { return RETURN; }
"print"|"printf"            { return PRINT; }

[0-9]+                      { yylval.ival = atoi(yytext); return NUMBER; }
[a-zA-Z_][a-zA-Z0-9_]*      { yylval.str = strdup(yytext); return ID; }

\"(\\.|[^"\\])*\"           { yylval.str = strdup(yytext); return STRING_LITERAL; }

"+"|"-"|"*"|"/"|"="|"<"|">"|"!"|"&"|"|" { return yytext[0]; }
";"|","|"{"|"}"|"("|")"|"["|"]"         { return yytext[0]; }

[ \t\r\n]+                  { /* Ignore whitespace */ }
"//".*                      { /* Ignore single-line comments */ }
"/*"([^*]|\*+[^*/])*\*+"/"  { /* Ignore multi-line comments */ }

.                           { printf("Lexical Error at line %d: Unknown character %s\n", yylineno, yytext); }

%%