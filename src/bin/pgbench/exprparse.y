%{
/*-------------------------------------------------------------------------
 *
 * exprparse.y
 *	  bison grammar for a simple expression syntax
 *
 * Portions Copyright (c) 1996-2016, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres_fe.h"

#include "pgbench.h"

PgBenchExpr *expr_parse_result;

static PgBenchExprList *make_elist(PgBenchExpr *exp, PgBenchExprList *list);
static PgBenchExpr *make_integer_constant(int64 ival);
static PgBenchExpr *make_variable(char *varname);
static PgBenchExpr *make_op(const char *operator, PgBenchExpr *lexpr,
		PgBenchExpr *rexpr);
static int find_func(const char *fname);
static PgBenchExpr *make_func(const int fnumber, PgBenchExprList *args);

%}

%expect 0
%name-prefix="expr_yy"

%union
{
	int64		ival;
	char	   *str;
	PgBenchExpr *expr;
	PgBenchExprList *elist;
}

%type <elist> elist
%type <expr> expr
%type <ival> INTEGER function
%type <str> VARIABLE FUNCTION

%token INTEGER VARIABLE FUNCTION
%token CHAR_ERROR /* never used, will raise a syntax error */

/* Precedence: lowest to highest */
%left	'+' '-'
%left	'*' '/' '%'
%right	UMINUS

%%

result: expr				{ expr_parse_result = $1; }

elist:                  	{ $$ = NULL; }
	| expr 					{ $$ = make_elist($1, NULL); }
	| elist ',' expr		{ $$ = make_elist($3, $1); }
	;

expr: '(' expr ')'			{ $$ = $2; }
	| '+' expr %prec UMINUS	{ $$ = $2; }
	| '-' expr %prec UMINUS	{ $$ = make_op("-", make_integer_constant(0), $2); }
	| expr '+' expr			{ $$ = make_op("+", $1, $3); }
	| expr '-' expr			{ $$ = make_op("-", $1, $3); }
	| expr '*' expr			{ $$ = make_op("*", $1, $3); }
	| expr '/' expr			{ $$ = make_op("/", $1, $3); }
	| expr '%' expr			{ $$ = make_op("%", $1, $3); }
	| INTEGER				{ $$ = make_integer_constant($1); }
	| VARIABLE 				{ $$ = make_variable($1); }
	| function '(' elist ')'{ $$ = make_func($1, $3); }
	;

function: FUNCTION			{ $$ = find_func($1); pg_free($1); }
	;

%%

static PgBenchExpr *
make_integer_constant(int64 ival)
{
	PgBenchExpr *expr = pg_malloc(sizeof(PgBenchExpr));

	expr->etype = ENODE_INTEGER_CONSTANT;
	expr->u.integer_constant.ival = ival;
	return expr;
}

static PgBenchExpr *
make_variable(char *varname)
{
	PgBenchExpr *expr = pg_malloc(sizeof(PgBenchExpr));

	expr->etype = ENODE_VARIABLE;
	expr->u.variable.varname = varname;
	return expr;
}

static PgBenchExpr *
make_op(const char *operator, PgBenchExpr *lexpr, PgBenchExpr *rexpr)
{
	return make_func(find_func(operator),
					 make_elist(rexpr, make_elist(lexpr, NULL)));
}

/*
 * List of available functions:
 * - fname: function name
 * - nargs: number of arguments
 *          -1 is a special value for min & max meaning #args >= 1
 * - tag: function identifier from PgBenchFunction enum
 */
static struct
{
	char * fname;
	int nargs;
	PgBenchFunction tag;
} PGBENCH_FUNCTIONS[] = {
	/* parsed as operators, executed as functions */
	{ "+", 2, PGBENCH_ADD },
	{ "-", 2, PGBENCH_SUB },
	{ "*", 2, PGBENCH_MUL },
	{ "/", 2, PGBENCH_DIV },
	{ "%", 2, PGBENCH_MOD },
	/* actual functions */
	{ "abs", 1, PGBENCH_ABS },
	{ "min", -1, PGBENCH_MIN },
	{ "max", -1, PGBENCH_MAX },
	{ "debug", 1, PGBENCH_DEBUG },
	/* keep as last array element */
	{ NULL, 0, 0 }
};

/*
 * Find a function from its name
 *
 * return the index of the function from the PGBENCH_FUNCTIONS array
 * or fail if the function is unknown.
 */
static int
find_func(const char * fname)
{
	int i = 0;

	while (PGBENCH_FUNCTIONS[i].fname)
	{
		if (pg_strcasecmp(fname, PGBENCH_FUNCTIONS[i].fname) == 0)
			return i;
		i++;
	}

	expr_yyerror_more("unexpected function name", fname);

	/* not reached */
	return -1;
}

/* Expression linked list builder */
static PgBenchExprList *
make_elist(PgBenchExpr *expr, PgBenchExprList *list)
{
	PgBenchExprLink * cons;

	if (list == NULL)
	{
		list = pg_malloc(sizeof(PgBenchExprList));
		list->head = NULL;
		list->tail = NULL;
	}

	cons = pg_malloc(sizeof(PgBenchExprLink));
	cons->expr = expr;
	cons->next = NULL;

	if (list->head == NULL)
		list->head = cons;
	else
		list->tail->next = cons;

	list->tail = cons;

	return list;
}

/* Return the length of an expression list */
static int
elist_length(PgBenchExprList *list)
{
	PgBenchExprLink *link = list != NULL? list->head: NULL;
	int len = 0;

	for (; link != NULL; link = link->next)
		len++;

	return len;
}

/* Build function call expression */
static PgBenchExpr *
make_func(const int fnumber, PgBenchExprList *args)
{
	PgBenchExpr *expr = pg_malloc(sizeof(PgBenchExpr));

	Assert(fnumber >= 0);

	if (PGBENCH_FUNCTIONS[fnumber].nargs >= 0 &&
		PGBENCH_FUNCTIONS[fnumber].nargs != elist_length(args))
		expr_yyerror_more("unexpected number of arguments",
						  PGBENCH_FUNCTIONS[fnumber].fname);

	/* check at least one arg for min & max */
	if (PGBENCH_FUNCTIONS[fnumber].nargs == -1 &&
		elist_length(args) == 0)
		expr_yyerror_more("at least one argument expected",
						  PGBENCH_FUNCTIONS[fnumber].fname);

	expr->etype = ENODE_FUNCTION;
	expr->u.function.function = PGBENCH_FUNCTIONS[fnumber].tag;

	/* only the link is used, the head/tail is not useful anymore */
	expr->u.function.args = args != NULL? args->head: NULL;
	if (args)
		pg_free(args);

	return expr;
}

#include "exprscan.c"
