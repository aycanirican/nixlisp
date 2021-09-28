{ lib, parser }:

let

exprType = expr:
  if builtins.isList expr then "vector"
  else if builtins.isInt expr then "number"
  else if builtins.isNull expr then "null"
  else if builtins.isString expr then "string"
  else if builtins.isFunction expr then "nix_function"
  else if builtins.isAttrs expr then
    if builtins.hasAttr "__nixlisp_term" expr
    then expr.type
    else "attrset"
  else throw "unexpected type: ${builtins.typeOf expr}";

assertSymbol = expr:
  if exprType expr == "symbol"
  then expr.value
  else throw "expected a symbol, but got a ${exprType expr}";

assertCons = expr:
  if exprType expr == "cons"
  then expr.value
  else throw "expected a cons, but got a ${exprType expr}";

assertSymbols = expr:
  if expr == null
  then []
  else
    let c = assertCons expr;
    in  [assertSymbol c.car] ++ assertSymbols c.cdr;

matchList = keys: expr:
  if builtins.length keys == 0
  then if expr == null
       then {}
       else throw "list too long"
  else let c = assertCons expr;
       in  { "${builtins.elemAt keys 0}" = c.car; } // matchList (lib.drop 1 keys) c.cdr;

mapList = f: xs:
  if xs == null
  then null
  else
    let c = assertCons xs;
    in  {  __nixlisp_term = true;
           type = "cons";
           value = { car = f c.car; cdr = mapList f c.cdr; };
        };

evaluateList = env: mapList (x: (evaluate env x).result);

mkSymbol = str: { __nixlisp_term = true; type = "symbol"; value = str; };

evaluate = env: expr:
  if exprType expr == "number" then { inherit env; result = expr; }
  else if exprType expr == "null" then { inherit env; result = null; }
  else if exprType expr == "symbol" then { inherit env; result = env."${expr.value}"; }
  else if exprType expr == "string" then { inherit env; result = expr; }
  else if exprType expr == "vector" then { inherit env; result = expr; }
  else if exprType expr == "cons" then
    let
      car = expr.value.car;
      cdr = expr.value.cdr;
    in
      if car == mkSymbol "define" then
        # 'define' evaluates the second arguments and assigns it to the first symbol
        let c  = matchList ["name" "value"] cdr;
            name = assertSymbol c.name;
            value = (evaluate env c.value).result;
        in  { env = env // { ${name} = value; }; result = null; }
      else if car == mkSymbol "quote" then
        # 'quote ' returns the only argument without evaluating
        let c  = matchList ["arg"] cdr;
        in  { inherit env; result = c.arg; }
      else if car == mkSymbol "define-macro" then
        # 'define-macro' creates a 'macro' object carrying the lambda.
        let c = matchList ["name" "lambda"] cdr;
            name = assertSymbol c.name;
            lambda = evaluate env c.lambda; # TODO: error out when this is not actually a lambda
            value = { __nixlisp_term = true; type = "macro"; value = lambda; };
        in { env = env // { ${name} = value; }; result = null; }
      else if car == mkSymbol "if" then
        # if evaluates the first argument, if null or false, evaluates & returns the third; else the second
        let c = matchList ["cond" "if_t" "if_f"] cdr;
            cond = (evaluate env c.cond).result;
            branch = if cond == null || cond == false then c.if_f else c.if_t;
            result = (evaluate env branch).result;
        in { inherit env result; }
      else if car == mkSymbol "begin" then
        # evaluates all arguments one after another in the same environment
        let go = prev: xs:
              if xs == null
              then prev
              else let c = assertCons xs;
                       curr = evaluate prev.env c.car;
                   in  go curr c.cdr;
            result = (go { inherit env; result = null; } cdr).result;
        in { inherit env result; }
      else if car == mkSymbol "lambda" then
        # 'lambda' creates a 'lambda' object carrying the arguments and the body.
        let c = matchList ["args" "body"] cdr;
            args = c.args;
            body = c.body;
            result = { __nixlisp_term = true; type = "lambda"; value = { inherit args body env; }; };
        in { inherit env result; }
      else
        let fun = (evaluate env expr.value.car).result; # TODO actually run evaluate here, in case the first argument is a callable
        in  if exprType fun == "nix_function" then
               # when we have a nix function, we simply pass all the evaluated arguments one after another
               let go = f: x:
                     if x == null then f
                     else let c = assertCons x;
                           in go (f (evaluate env c.car).result) c.cdr;
                in { inherit env; result = go fun cdr; }
            else if exprType fun == "lambda" then
              # when we have a lambda, we create a new env; assigning (evaluated) arguments to the bindings.
              # if the last binding is null (for a list), every argument is assigned to a binding.
              # if the last binding is not null (dotted pair), rest of the arguments is assigned to last binding (varargs).
              let go = env: bindings: args:
                    if bindings == null then
                      if args == null
                      then env
                      else throw "too many arguments"
                    else if exprType bindings == "cons" then
                      let b = assertCons bindings;
                          c = assertCons args;
                          name = assertSymbol b.car;
                       in go (env // { "${name}" = (evaluate env c.car).result; }) b.cdr c.cdr
                    else
                      # varargs
                      let binding = assertSymbol bindings;
                      in env // { "${binding}" = evaluateList env args; };
                  innerEnv = go (env // fun.value.env) fun.value.args cdr;
              in { inherit env; result = (evaluate innerEnv fun.value.body).result; }
            else if exprType fun == "macro" then
              throw "TODO"
            else
              throw "Tried to call ${car}, but it is a ${exprType car}."
  else throw "Unexpected type: ${exprType expr}.";

evaluateProgram = env: program:
  if builtins.isList program
  then lib.foldl (acc: x: evaluate acc.env x) { inherit env; value = null; } (program)
  else throw "invariant violation: program is not a list";

# Build the standard environment


prims = {
  # values
  __prim_null = null;
  __prim_vector_empty = [];
  __prim_attrset_empty = {};

  # operators
  __prim_plus = i: j: i + j;
  __prim_product = i: j: i * j;
  __prim_minus = i: j: i - j;
  __prim_equals = i: j: i == j;

  # accessors
  __prim_car = xs: (assertCons xs).car;
  __prim_cdr = xs: (assertCons xs).cdr;

  # builtins
  __prim_builtins = builtins;
  __prim_getAttr = builtins.getAttr; # we need this directly to access the builtins

  # conversion
  # __prim_lambda_to_nix = x:
  #   if exprType x == "lambda"
  #   then
  #     let go
  #   else throw "expecting a lambda, but got ${exprType x}";
};

stdenv =
  (evaluateProgram prims (parser.parseFile ../stdlib.nixlisp)).env;

in

{
  eval = env: i: (evaluateProgram (stdenv // env) i).result;
}
