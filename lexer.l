%{
#include "parser.tab.h"
#include <string.h>
#include <stdlib.h>
%}

%option noyywrap
%option yylineno

%%
"#".*                        { /* Ignore preprocessor directives */ }

"for"                         { return FOR; }
"do"                           { return DO; }
"break"                        { return BREAK; }
"continue"                     { return CONTINUE; }
"int"|"float"|"double"|"char"|"void"|"long"|"short"|"unsigned" { yylval.str = strdup(yytext); return TYPE; }
"if"                        { return IF; }
"else"                      { return ELSE; }
"while"                     { return WHILE; }
"return"                    { return RETURN; }
"printf"|"print"            { return PRINT; }

"=="                        { return EQ; }
"!="                        { return NE; }
"<="                        { return LE; }
">="                        { return GE; }
"&&"                        { return AND; }
"||"                        { return OR; }
"++"                        { return INC; }
"--"                        { return DEC; }
"+="                        { return PLUSEQ; }
"-="                        { return MINUSEQ; }
"*="                        { return MULEQ; }
"/="                        { return DIVEQ; }

[0-9]+\.[0-9]+              { yylval.ival = (int)atof(yytext); return NUMBER; }
[0-9]+                      { yylval.ival = atoi(yytext); return NUMBER; }
[a-zA-Z_][a-zA-Z0-9_]*      { yylval.str = strdup(yytext); return ID; }
\"(\\.|[^"\\])*\"           { yylval.str = strdup(yytext); return STRING_LITERAL; }

[=+\-*/<>()\[\]{};,?:!]     { return yytext[0]; }

[ \t\r\n]+                  { /* Ignore whitespace */ }
"//".*                      { /* Ignore single-line comments */ }
"/*"([^*]|\*+[^*/])*\*+"/"  { /* Ignore multi-line comments */ }

.                           { /* Ignore unrecognized characters securely */ }
%%
