%option noyywrap nodefault yylineno

%{
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <ctype.h>

/* ===================== CONFIGURATION ===================== */
#define MAX_VARS 1024
#define MAX_CODE 4096
#define MAX_TOKS 8192

/* Flex forward declarations */
extern FILE *yyin;
int yylex(void);

/* ===================== SYMBOL TABLE ===================== */
typedef struct {
    char name[32];
    int  value;
    int  defined;
} Var;

static Var vars[MAX_VARS];
static int varCount = 0;

/* Find a variable by name in the symbol table */
static int find_var(const char *name) {
    for (int i = 0; i < varCount; i++)
        if (strcmp(vars[i].name, name) == 0) return i;
    return -1;
}

/* Ensure a variable exists in the symbol table, creating it if necessary */
static int ensure_var(const char *name) {
    int i = find_var(name);
    if (i >= 0) return i;
    if (varCount >= MAX_VARS) {
        fprintf(stderr, "Too many variables\n");
        exit(1);
    }
    strncpy(vars[varCount].name, name, sizeof(vars[varCount].name)-1);
    vars[varCount].name[sizeof(vars[varCount].name)-1] = '\0';
    vars[varCount].value = 0;
    vars[varCount].defined = 0;
    return varCount++;
}

/* Set the value of a variable */
static void set_var(const char *name, int value) {
    int i = ensure_var(name);
    vars[i].value  = value;
    vars[i].defined = 1;
}

/* Get the value of a variable, with a warning if it's undefined */
static int get_var_value(const char *name) {
    int i = ensure_var(name);
    if (!vars[i].defined) {
        fprintf(stderr, "Warning (line %d): variable '%s' was undefined; assuming 0\n", yylineno, name);
        vars[i].defined = 1;
        vars[i].value   = 0;
    }
    return vars[i].value;
}

/* ===================== CODE BUFFERS ===================== */
typedef struct { char s[128]; } Line;

static Line tac[MAX_CODE], tacOpt[MAX_CODE], assem[MAX_CODE];
static int tacN = 0, tacOptN = 0, asmN = 0;

/* Append a formatted line to a code buffer */
static void add_line(Line *arr, int *n, const char *fmt, ...) {
    if (*n >= MAX_CODE) {
        fprintf(stderr, "Too many code lines\n");
        exit(1);
    }
    va_list args;
    va_start(args, fmt);
    vsnprintf(arr[*n].s, sizeof(arr[*n].s), fmt, args);
    va_end(args);
    (*n)++;
}

#define ADD_TAC(...)    add_line(tac,    &tacN,    __VA_ARGS__)
#define ADD_TACOPT(...) add_line(tacOpt, &tacOptN, __VA_ARGS__)
#define ADD_ASM(...)    add_line(assem,  &asmN,    __VA_ARGS__)

/* Reset all code buffers */
static void reset_code_buffers(void) {
    tacN = tacOptN = asmN = 0;
}

/* ===================== TOKEN STREAM (for display) ===================== */
typedef enum {
    T_ID, T_NUM, T_PRINT, T_EQ, T_PLUS, T_MINUS, T_MUL, T_DIV,
    T_SEMI, T_LP, T_RP
} TokType;

typedef struct {
    TokType type;
    char    lexeme[32];
    int     line;
} Tok;

static Tok toks[MAX_TOKS];
static int tokN = 0;

/* Add a token to the token stream buffer */
static void add_tok(TokType t, const char *lex) {
    if (tokN >= MAX_TOKS) {
        fprintf(stderr, "Too many tokens\n");
        exit(1);
    }
    toks[tokN].type = t;
    strncpy(toks[tokN].lexeme, lex, sizeof(toks[tokN].lexeme)-1);
    toks[tokN].lexeme[sizeof(toks[tokN].lexeme)-1] = '\0';
    toks[tokN].line = yylineno;
    tokN++;
}

/* Reset the token stream buffer */
static void reset_tok_stream(void){
    tokN = 0;
}

/* ===================== EXPRESSION (INFIX) BUFFER ====== */
typedef enum { E_ID, E_NUM, E_OP, E_LP, E_RP } EType;
typedef struct { EType t; char lex[32]; } ETok;

static ETok exprToks[MAX_TOKS];
static int  exprN = 0;

/* Add a token to the expression buffer */
static void expr_add(EType t, const char *lx){
    if (exprN >= MAX_TOKS) {
        fprintf(stderr,"Too many expression tokens\n");
        exit(1);
    }
    exprToks[exprN].t = t;
    strncpy(exprToks[exprN].lex, lx, 31);
    exprToks[exprN].lex[31]='\0';
    exprN++;
}

/* Reset the expression buffer */
static void reset_expr(void){
    exprN = 0;
}

/* ===================== RPN BUFFER & CONVERSION ===================== */
static ETok rpn[MAX_TOKS];
static int rpnN = 0;

/* Get operator precedence */
static inline int prec(char op){
    return (op=='*'||op=='/')?2:(op=='+'||op=='-')?1:0;
}

/* Check for right associativity (all operators are left-associative here) */
static inline int right_assoc(char op){
    (void)op;
    return 0;
}

/* Convert infix expression to Reverse Polish Notation (RPN) */
static void to_rpn(void){
    rpnN = 0;
    char opStk[MAX_TOKS];
    int osp = 0;

    for (int i = 0; i < exprN; i++){
        ETok e = exprToks[i];
        if (e.t == E_ID || e.t == E_NUM){
            rpn[rpnN++] = e;
        } else if (e.t == E_OP){
            char op = e.lex[0];
            while (osp > 0){
                char top = opStk[osp-1];
                if (top == '(') break;
                if (prec(top) > prec(op) || (prec(top) == prec(op) && !right_assoc(op))){
                    ETok out;
                    out.t = E_OP;
                    out.lex[0] = top;
                    out.lex[1] = 0;
                    rpn[rpnN++] = out;
                    osp--;
                } else break;
            }
            opStk[osp++] = op;
        } else if (e.t == E_LP){
            opStk[osp++] = '(';
        } else if (e.t == E_RP){
            int ok = 0;
            while (osp > 0){
                char top = opStk[--osp];
                if (top == '('){
                    ok = 1;
                    break;
                }
                ETok out;
                out.t = E_OP;
                out.lex[0] = top;
                out.lex[1] = 0;
                rpn[rpnN++] = out;
            }
            if (!ok) fprintf(stderr,"Syntax error (line %d): mismatched ')'\n", yylineno);
        }
    }
    while (osp > 0){
        char top = opStk[--osp];
        if (top == '('){
            fprintf(stderr,"Syntax error (line %d): mismatched '('\n", yylineno);
            continue;
        }
        ETok out;
        out.t = E_OP;
        out.lex[0] = top;
        out.lex[1] = 0;
        rpn[rpnN++] = out;
    }
}

/* ===================== TAC GENERATION & OPTIMIZATION ===================== */
static int tempCounter = 0;

/* Evaluate an RPN expression to a single value */
static int eval_rpn_value(void){
    int st[MAX_TOKS], sp = 0;
    for (int i = 0; i < rpnN; i++){
        ETok e = rpn[i];
        if (e.t == E_NUM) {
            st[sp++] = atoi(e.lex);
        } else if (e.t == E_ID) {
            st[sp++] = get_var_value(e.lex);
        } else if (e.t == E_OP) {
            if (sp < 2) return 0;
            int b = st[--sp], a = st[--sp], r = 0;
            switch(e.lex[0]){
                case '+': r = a + b; break;
                case '-': r = a - b; break;
                case '*': r = a * b; break;
                case '/': r = (b ? a / b : 0); break;
            }
            st[sp++] = r;
        }
    }
    return (sp == 1) ? st[0] : 0;
}

/* Generate TAC and optimized TAC from RPN, storing the final value in lhs */
static void gen_tac_from_rpn_into_lhs(const char *lhs){
    char nameStk[MAX_TOKS][32];
    int sp = 0;
    unsigned char isC[MAX_TOKS] = {0};
    int cVal[MAX_TOKS] = {0};

    for (int i = 0; i < rpnN; i++){
        ETok e = rpn[i];
        if (e.t == E_NUM){
            strncpy(nameStk[sp], e.lex, 31);
            nameStk[sp][31] = '\0';
            isC[sp] = 1;
            cVal[sp] = atoi(e.lex);
            sp++;
        } else if (e.t == E_ID){
            strncpy(nameStk[sp], e.lex, 31);
            nameStk[sp][31] = '\0';
            isC[sp] = 0;
            cVal[sp] = 0;
            sp++;
        } else if (e.t == E_OP){
            if (sp < 2){
                fprintf(stderr,"Syntax error: not enough operands\n");
                return;
            }
            char rb[32], lb[32];
            int rC, lC, rv, lv;
            sp--;
            strncpy(rb, nameStk[sp], 31);
            rb[31] = '\0';
            rC = isC[sp];
            rv = cVal[sp];
            sp--;
            strncpy(lb, nameStk[sp], 31);
            lb[31] = '\0';
            lC = isC[sp];
            lv = cVal[sp];

            char t[16];
            snprintf(t, sizeof(t), "t%d", tempCounter++);
            char op = e.lex[0];
            
            // Generate unoptimized TAC
            ADD_TAC("%s = %s %c %s", t, lb, op, rb);
            
            // Check if both operands are constants for constant folding
            if (lC && rC){
                int res = 0;
                switch(op){
                    case '+': res = lv + rv; break;
                    case '-': res = lv - rv; break;
                    case '*': res = lv * rv; break;
                    case '/': res = (rv ? lv / rv : 0); break;
                }
                ADD_TACOPT("%s = %d", t, res);
                ADD_ASM("LDC %d", res);
                ADD_ASM("STORE %s", t);

                strncpy(nameStk[sp], t, 31);
                nameStk[sp][31] = '\0';
                isC[sp] = 1;
                cVal[sp] = res;
                sp++;
            } else {
                // If not constants, add the full operation to optimized TAC
                ADD_TACOPT("%s = %s %c %s", t, lb, op, rb);
                
                // Generate assembly
                if (lC) ADD_ASM("LDC %d", lv);
                else ADD_ASM("LOAD %s", lb);
                if (rC) ADD_ASM("LDC %d", rv);
                else ADD_ASM("LOAD %s", rb);
                switch(op){
                    case '+': ADD_ASM("ADD"); break;
                    case '-': ADD_ASM("SUB"); break;
                    case '*': ADD_ASM("MUL"); break;
                    case '/': ADD_ASM("DIV"); break;
                }
                ADD_ASM("STORE %s", t);

                strncpy(nameStk[sp], t, 31);
                nameStk[sp][31]='\0';
                isC[sp] = 0;
                cVal[sp] = 0;
                sp++;
            }
        }
    }

    // Final assignment of expression result to the LHS variable
    if (sp != 1) {
        fprintf(stderr, "Syntax error: leftover operands\n");
        return;
    }
    
    ADD_TAC("%s = %s", lhs, nameStk[0]);
    ADD_TACOPT("%s = %s", lhs, nameStk[0]);
    ADD_ASM("LOAD %s", nameStk[0]);
    ADD_ASM("STORE %s", lhs);
    
    int v = isC[0] ? cVal[0] : eval_rpn_value();
    set_var(lhs, v);
}

/* ===================== EMISSION & OUTPUT ===================== */
static void emit_current(const char *title){
    FILE *fp = fopen("output.txt","a");
    FILE *outs[2] = { stdout, fp };
    for (int i = 0; i < 2; i++){
        FILE *out = outs[i];
        if (!out) continue;
        fprintf(out, "=== %s ===\n", title ? title : "Statement");
        
        fprintf(out, "=== Tokens ===\n");
        for (int k = 0; k < tokN; k++) {
            const char *tn = "";
            switch (toks[k].type) {
                case T_ID: tn = "ID"; break;
                case T_NUM: tn = "NUM"; break;
                case T_PRINT: tn = "PRINT"; break;
                case T_EQ: tn = "="; break;
                case T_PLUS: tn = "+"; break;
                case T_MINUS: tn = "-"; break;
                case T_MUL: tn = "*"; break;
                case T_DIV: tn = "/"; break;
                case T_LP: tn = "("; break;
                case T_RP: tn = ")"; break;
                case T_SEMI: tn = ";"; break;
            }
            if (toks[k].type == T_ID || toks[k].type == T_NUM)
                fprintf(out, "(%s,%s) ", tn, toks[k].lexeme);
            else
                fprintf(out, "(%s) ", tn);
        }
        fprintf(out, "\n\n");
        
        fprintf(out, "=== Three-Address Code (TAC)\n");
        for (int j = 0; j < tacN; j++) fprintf(out, "%s\n", tac[j].s);
        
        fprintf(out, "\n=== TAC after optimization (constant fold)\n");
        for (int j = 0; j < tacOptN; j++) fprintf(out, "%s\n", tacOpt[j].s);
        
        fprintf(out, "\n=== Target pseudo-assembly ===\n");
        for (int j = 0; j < asmN; j++) fprintf(out, "%s\n", assem[j].s);
        
        fprintf(out, "\n");
    }
    if (fp) fclose(fp);

    reset_code_buffers();
    reset_tok_stream();
}

/* ===================== PARSER STATE ===================== */
typedef enum {
    PS_START,
    PS_HAVE_LHS,
    PS_IN_EXPR,
    PS_PRINT_WAIT_ID
} PState;

static PState pst = PS_START;
static char lhsVar[32] = "";
static char printName[32] = "";

/* Print a syntax error message */
static void syntax_error(const char *msg, const char *got){
    fprintf(stderr, "Syntax error (line %d): %s (got '%s')\n", yylineno, msg, got ? got : "");
}

/* Initialize state for a new assignment statement */
static void start_assignment(const char *lhs){
    strncpy(lhsVar, lhs, sizeof(lhsVar)-1);
    lhsVar[sizeof(lhsVar)-1] = '\0';
    reset_code_buffers();
    reset_expr();
    pst = PS_HAVE_LHS;
}

/* Finalize an assignment and emit output */
static void end_assignment_emit(void){
    to_rpn();
    gen_tac_from_rpn_into_lhs(lhsVar);
    emit_current(lhsVar);
    reset_expr();
    lhsVar[0] = '\0';
    pst = PS_START;
}

/* Handle a print statement and emit output */
static void do_print(const char *id){
    reset_code_buffers();
    ADD_TAC("print %s", id);
    ADD_TACOPT("print %s", id);
    ADD_ASM("PRINT %s", id);
    emit_current("print");
    pst = PS_START;
}

%}

/* ===================== REGULAR EXPRESSION RULES ===================== */
ID      [A-Za-z_][A-Za-z0-9_]*
NUM     [0-9]+
WS      [ \t]+

%%

{WS}            ;

";"             {
    add_tok(T_SEMI, yytext);
    if (pst == PS_IN_EXPR) end_assignment_emit();
    else if (pst == PS_PRINT_WAIT_ID && printName[0] != '\0') do_print(printName);
    else if (pst == PS_HAVE_LHS) syntax_error("expected expression after '='", yytext);
    else if (pst == PS_START && toks[tokN-1].type == T_SEMI) { /* do nothing */ }
    else syntax_error("unexpected semicolon", yytext);
}

\n              {
    if (pst == PS_IN_EXPR) end_assignment_emit();
    else if (pst == PS_PRINT_WAIT_ID && printName[0] != '\0') do_print(printName);
    else if (pst == PS_HAVE_LHS) syntax_error("expected expression after '='", "newline");
    else { /* do nothing */ }
}

"print"         {
    add_tok(T_PRINT, yytext);
    if (pst != PS_START) syntax_error("unexpected 'print'", yytext);
    else pst = PS_PRINT_WAIT_ID;
}

"="             {
    add_tok(T_EQ, yytext);
    if (pst == PS_HAVE_LHS) pst = PS_IN_EXPR;
    else syntax_error("expected identifier before '='", yytext);
}

"("             {
    add_tok(T_LP, yytext);
    if (pst == PS_IN_EXPR) expr_add(E_LP, "(");
    else syntax_error("unexpected '('", yytext);
}

")"             {
    add_tok(T_RP, yytext);
    if (pst == PS_IN_EXPR) expr_add(E_RP, ")");
    else syntax_error("unexpected ')'", yytext);
}

"+"             {
    add_tok(T_PLUS,  yytext);
    if (pst == PS_IN_EXPR) expr_add(E_OP, "+");
    else syntax_error("unexpected '+'", yytext);
}
"-"             {
    add_tok(T_MINUS, yytext);
    if (pst == PS_IN_EXPR) expr_add(E_OP, "-");
    else syntax_error("unexpected '-'", yytext);
}
"*"             {
    add_tok(T_MUL,   yytext);
    if (pst == PS_IN_EXPR) expr_add(E_OP, "*");
    else syntax_error("unexpected '*'", yytext);
}
"/"             {
    add_tok(T_DIV,   yytext);
    if (pst == PS_IN_EXPR) expr_add(E_OP, "/");
    else syntax_error("unexpected '/'", yytext);
}

{ID}            {
    add_tok(T_ID, yytext);
    if (pst == PS_START){
        start_assignment(yytext);
    } else if (pst == PS_PRINT_WAIT_ID){
        strncpy(printName, yytext, 31);
        printName[31] = '\0';
    } else if (pst == PS_IN_EXPR){
        expr_add(E_ID, yytext);
    } else {
        syntax_error("unexpected identifier", yytext);
    }
}

{NUM}           {
    add_tok(T_NUM, yytext);
    if (pst == PS_IN_EXPR) expr_add(E_NUM, yytext);
    else syntax_error("unexpected number", yytext);
}

.               {
    syntax_error("invalid character", yytext);
}

%%

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <inputfile>\n", argv[0]);
        return 1;
    }

    FILE *in = fopen(argv[1], "r");
    if (!in) {
        perror(argv[1]);
        return 1;
    }

    FILE *fp = fopen("output.txt", "w");
    if (fp) fclose(fp);

    reset_code_buffers();
    reset_tok_stream();
    reset_expr();
    yyin = in;
    yylex();
    fclose(in);

    // Handle last line if it doesn't end with a newline or semicolon
    if (pst == PS_IN_EXPR && exprN > 0) {
        end_assignment_emit();
    } else if (pst == PS_PRINT_WAIT_ID && printName[0] != '\0') {
        do_print(printName);
    }
    
    return 0;
}
