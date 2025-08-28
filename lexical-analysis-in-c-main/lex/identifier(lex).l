%{
#include <stdio.h>
#include <stdlib.h>

FILE *out;  // output file pointer

%}

%%

"int"|"float"|"char"|"return"|"if"|"else"   { fprintf(out, "Keyword: %s\n", yytext); }
[0-9]+                                      { fprintf(out, "Number: %s\n", yytext); }
[a-zA-Z_][a-zA-Z0-9_]*                      { fprintf(out, "Identifier: %s\n", yytext); }
[+\-*/=<>]                                  { fprintf(out, "Operator: %s\n", yytext); }
[ \t\n]+                                    ;   // ignore whitespace
.                                           { fprintf(out, "Unknown: %s\n", yytext); }

%%

int main(int argc, char *argv[]) {
    if (argc != 3) {
        printf("Usage: %s <inputfile> <outputfile>\n", argv[0]);
        exit(1);
    }

    yyin = fopen(argv[1], "r");   // input file
    if (!yyin) {
        perror("Error opening input file");
        exit(1);
    }

    out = fopen(argv[2], "w");    // output file
    if (!out) {
        perror("Error opening output file");
        exit(1);
    }

    yylex();   // start lexical analysis

    fclose(yyin);
    fclose(out);
    return 0;
}

int yywrap() {
    return 1;
}
