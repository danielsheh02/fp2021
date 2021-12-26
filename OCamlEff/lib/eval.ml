open Ast
open Env
open Base
open Format

module type MONAD_FAIL = sig
  include Base.Monad.S2

  val fail : 'e -> ('a, 'e) t
end

module Interpret (M : MONAD_FAIL) = struct
  open M

  type state =
    { env: exval Env.id_t
    ; context: effhval Env.eff_t
    }

  and effhval = EffHV of pat * ident * exp

  and exval =
    | IntV of int
    | BoolV of bool
    | StringV of string
    | TupleV of exval list
    | ListV of exval list
    | FunV of pat * exp * state
    | Eff1V of capitalized_ident
    | Eff2V of capitalized_ident * exval
    | EffDec1V of capitalized_ident * tyexp
    | EffDec2V of capitalized_ident * tyexp * tyexp
    | ContV of ident

  type error =
    | Match_fail of pat * exval
    | Tuple_compare of exval * exval
    | No_handler of capitalized_ident
    | No_effect of capitalized_ident
    | Wrong_infix_op of infix_op * exval * exval
    | Wrong_unary_op of unary_op * exval
    | Undef_var of ident
    | Interp_error of exp
    | Match_exhaust of exp
    | Not_cont_val of ident

  let lookup_in_env id state = lookup_id_map id state.env
  let lookup_in_context id state = lookup_eff_map id state.context
  let extend_env id v state = { state with env = extend_id_map id v state.env }

  let extend_context id v state =
    { state with context = extend_eff_map id v state.context }
  ;;

  let rec match_pat pat var =
    match pat, var with
    | PWild, _ -> M.return []
    | PVar name, v -> M.return [ name, v ]
    | PConst x, v ->
      (match x, v with
      | CInt a, IntV b when a = b -> M.return []
      | CString a, StringV b when a == b -> M.return []
      | CBool a, BoolV b when a == b -> M.return []
      | _ -> M.fail (Match_fail (PConst x, v)))
    | PCons (pat1, pat2), ListV (hd :: tl) ->
      match_pat pat1 hd
      >>= fun hd_matched ->
      match_pat pat2 (ListV tl) >>= fun tl_matched -> M.return (hd_matched @ tl_matched)
    | PNil, ListV [] -> return []
    | PTuple pats, TupleV vars ->
      (try
         return
           (List.fold2_exn pats vars ~init:[] ~f:(fun binds pat var ->
                match_pat pat var >>= fun matched -> binds @ matched))
       with
      | _ -> fail (Match_fail (PTuple pats, TupleV vars)))
    | PEffect1 name_p, Eff1V name_exp when name_p == name_exp -> return []
    | PEffect2 (name_p, p), Eff2V (name_exp, v) when name_p == name_exp -> match_pat p v
    | PEffectH (pat, _), Eff1V name_exp -> match_pat pat (Eff1V name_exp)
    | PEffectH (pat, _), Eff2V (name_exp, v) -> match_pat pat (Eff2V (name_exp, v))
    | a, b -> fail (Match_fail (a, b))
  ;;

  let apply_infix_op op x y =
    match op, x, y with
    | Add, IntV x, IntV y -> return (IntV (x + y))
    | Sub, IntV x, IntV y -> return (IntV (x - y))
    | Mul, IntV x, IntV y -> return (IntV (x * y))
    | Div, IntV x, IntV y -> return (IntV (x / y))
    (* "<" block *)
    | Less, IntV x, IntV y -> return (BoolV (x < y))
    | Less, StringV x, StringV y -> return (BoolV String.(x < y))
    | Less, TupleV x, TupleV y when List.length x = List.length y ->
      return (BoolV Poly.(x < y))
    | Less, ListV x, ListV y -> return (BoolV Poly.(x < y))
    (* "<=" block *)
    | Leq, IntV x, IntV y -> return (BoolV (x <= y))
    | Leq, StringV x, StringV y -> return (BoolV Poly.(x <= y))
    | Leq, TupleV x, TupleV y when List.length x = List.length y ->
      return (BoolV Poly.(x <= y))
    | Leq, ListV x, ListV y -> return (BoolV Poly.(x <= y))
    (* ">" block *)
    | Gre, IntV x, IntV y -> return (BoolV (x > y))
    | Gre, StringV x, StringV y -> return (BoolV Poly.(x > y))
    | Gre, TupleV x, TupleV y when List.length x = List.length y ->
      return (BoolV Poly.(x > y))
    | Gre, ListV x, ListV y -> return (BoolV Poly.(x > y))
    (* ">=" block *)
    | Geq, IntV x, IntV y -> return (BoolV (x >= y))
    | Geq, StringV x, StringV y -> return (BoolV Poly.(x >= y))
    | Geq, TupleV x, TupleV y when List.length x = List.length y ->
      return (BoolV Poly.(x >= y))
    | Geq, ListV x, ListV y -> return (BoolV Poly.(x >= y))
    (* "=" block *)
    | Eq, IntV x, IntV y -> return (BoolV (x == y))
    | Eq, StringV x, StringV y -> return (BoolV (x == y))
    | Eq, BoolV x, BoolV y -> return (BoolV (x == y))
    | Eq, TupleV x, TupleV y -> return (BoolV (x == y))
    | Eq, ListV x, ListV y -> return (BoolV (x == y))
    (* "!=" block *)
    | Neq, IntV x, IntV y -> return (BoolV (x != y))
    | Neq, StringV x, StringV y -> return (BoolV (x != y))
    | Neq, BoolV x, BoolV y -> return (BoolV (x != y))
    | Neq, TupleV x, TupleV y -> return (BoolV (x != y))
    | Neq, ListV x, ListV y -> return (BoolV (x != y))
    (* Other bool ops *)
    | And, BoolV x, BoolV y -> return (BoolV (x && y))
    | Or, BoolV x, BoolV y -> return (BoolV (x || y))
    (* failures *)
    | _, TupleV x, TupleV y when List.length x != List.length y ->
      fail (Tuple_compare (TupleV x, TupleV y))
    | a, b, c -> fail (Wrong_infix_op (a, b, c))
  ;;

  let apply_unary_op op x =
    match op, x with
    | Minus, IntV x -> return (IntV (-x))
    | Not, BoolV x -> return (BoolV (not x))
    | a, b -> fail (Wrong_unary_op (a, b))
  ;;

  let rec scan_cases = function
    | hd :: tl ->
      (match hd with
      | PEffectH (PEffect1 name, cont), exp ->
        (name, EffHV (PEffect1 name, cont, exp)) :: scan_cases tl
      | PEffectH (PEffect2 (name, pat), cont), exp ->
        (name, EffHV (PEffect2 (name, pat), cont, exp)) :: scan_cases tl
      | _ -> scan_cases tl)
    | [] -> []
  ;;

  let rec eval_exp state = function
    | ENil -> M.return (ListV [])
    | EConst x ->
      (match x with
      | CInt x -> M.return (IntV x)
      | CBool x -> M.return (BoolV x)
      | CString x -> M.return (StringV x))
    | EVar x ->
      (try M.return (lookup_in_env x state) with
      | Not_bound -> fail (Undef_var x))
    | EOp (op, x, y) ->
      eval_exp state x
      >>= fun exp_x -> eval_exp state y >>= fun exp_y -> apply_infix_op op exp_x exp_y
    | EUnOp (op, x) -> eval_exp state x >>= fun exp_x -> apply_unary_op op exp_x
    | ETuple exps ->
      M.return
        (TupleV (List.map exps ~f:(fun exp -> eval_exp state exp >>= fun res -> res)))
    | ECons (exp1, exp2) ->
      eval_exp state exp1
      >>= fun exp1_evaled ->
      eval_exp state exp2
      >>= fun exp2_evaled ->
      (match exp2_evaled with
      | ListV list -> M.return (ListV (exp1_evaled :: list))
      | x -> M.return (ListV [ exp1_evaled; x ]))
    | EIf (exp1, exp2, exp3) ->
      eval_exp state exp1
      >>= fun evaled ->
      (match evaled with
      | BoolV true -> eval_exp state exp2
      | BoolV false -> eval_exp state exp3
      | _ -> fail (Interp_error (EIf (exp1, exp2, exp3))))
    | ELet (bindings, exp1) ->
      let gen_state =
        List.fold bindings ~init:state ~f:(fun state binding ->
            match binding with
            | _, pat, exp ->
              eval_exp state exp
              >>= fun evaled ->
              let binds = match_pat pat evaled in
              List.fold binds ~init:state ~f:(fun state (id, v) -> extend_env id v state))
      in
      eval_exp gen_state exp1
    | EFun (pat, exp) -> M.return (FunV (pat, exp, state))
    | EApp (exp1, exp2) ->
      eval_exp state exp1
      >>= fun evaled ->
      (match evaled with
      | FunV (pat, exp, fstate) ->
        eval_exp state exp2
        >>= fun evaled2 ->
        match_pat pat evaled2
        >>= fun binds ->
        let new_state =
          List.fold binds ~init:fstate ~f:(fun state (id, v) -> extend_env id v state)
        in
        let very_new_state =
          match exp1 with
          | EVar x -> extend_env x evaled new_state
          | _ -> new_state
        in
        eval_exp { very_new_state with context = state.context } exp
      | _ -> fail (Interp_error (EApp (exp1, exp2))))
    | EMatch (exp, mathchings) ->
      let effh = scan_cases mathchings in
      let exp_state =
        List.fold effh ~init:state ~f:(fun state (id, v) -> extend_context id v state)
      in
      eval_exp exp_state exp
      >>= fun evaled ->
      let rec do_match = function
        | [] -> fail (Match_exhaust (EMatch (exp, mathchings)))
        | (pat, exp) :: tl ->
          (try
             match_pat pat evaled
             >>= fun binds ->
             let state =
               List.fold binds ~init:state ~f:(fun state (id, v) -> extend_env id v state)
             in
             eval_exp state exp
           with
          | Match_fail (_, _) -> do_match tl)
      in
      do_match mathchings
    | EPerform exp ->
      eval_exp state exp
      >>= fun eff ->
      (match eff with
      | Eff1V name ->
        let (EffHV (pat, cont_val, exph)) =
          try lookup_in_context name state with
          | Not_bound -> fail (No_handler name)
        in
        let _ =
          try lookup_in_env name state with
          | Not_bound -> fail (No_effect name)
        in
        let _ = match_pat pat (Eff1V name) in
        eval_exp (extend_env cont_val (ContV cont_val) state) exph
      | Eff2V (name, exval) ->
        let (EffHV (pat, cont_val, exph)) =
          try lookup_in_context name state with
          | Not_bound -> fail (No_handler name)
        in
        let _ =
          try lookup_in_env name state with
          | Not_bound -> fail (No_effect name)
        in
        match_pat pat (Eff2V (name, exval))
        >>= fun binds ->
        let state =
          List.fold binds ~init:state ~f:(fun state (id, v) -> extend_env id v state)
        in
        eval_exp (extend_env cont_val (ContV cont_val) state) exph
      | _ -> fail (Interp_error (EPerform exp)))
    | EContinue (cont_val, exp) ->
      let _ =
        try lookup_in_env cont_val state with
        | Not_bound -> fail (Not_cont_val cont_val)
      in
      eval_exp state exp
    | EEffect1 name -> M.return (Eff1V name)
    | EEffect2 (name, exp) ->
      eval_exp state exp >>= fun evaled -> M.return (Eff2V (name, evaled))
  ;;

  let eval_dec state = function
    | DLet bindings ->
      (match bindings with
      | _, pat, exp ->
        eval_exp state exp
        >>= fun evaled ->
        match_pat pat evaled
        >>= fun binds ->
        let state =
          List.fold binds ~init:state ~f:(fun state (id, v) -> extend_env id v state)
        in
        M.return state)
    | DEffect1 (name, tyexp) ->
      let state = extend_env name (EffDec1V (name, tyexp)) state in
      M.return state
    | DEffect2 (name, tyexp1, tyexp2) ->
      let state = extend_env name (EffDec2V (name, tyexp1, tyexp2)) state in
      M.return state
  ;;

  let eval_test decls expected =
    try
      let init_state = { env = empty_id_map; context = empty_eff_map } in
      let state =
        List.fold decls ~init:init_state ~f:(fun state decl -> eval_dec state decl)
      in
      let res =
        IdMap.fold
          (fun k v ln ->
            let new_res = ln ^ Printf.sprintf "%s -> %s; " k (exval_to_str v) in
            new_res)
          state.env
          ""
      in
      if res = expected
      then true
      else (
        Printf.printf "%s\n" res;
        false)
    with
    | Tuple_compare
      when expected = "Interpretation error: Cannot compare tuples of different size." ->
      true
    | Match_fail when expected = "Interpretation error: pattern-match failed." -> true
    | _ -> false
  ;;
end

let test code expected =
  let open Interpret (Result) in
  match Parser.parse Parser.prog code with
  | Result.Ok prog -> eval_test prog expected
  | _ -> failwith "Parse error"
;;

(* Eval test 1 *)

(*
   let x = 1
*)
let%test _ = eval_test [ DLet (false, PVar "x", EConst (CInt 1)) ] "x -> 1; "

(* Eval test 2 *)

(*
   let (x, y) = (1, 2)
*)
(* let%test _ =
   eval_test
    [ DLet
        (false, PTuple [ PVar "x"; PVar "y" ], ETuple [ EConst (CInt 1); EConst (CInt 2) ])
    ]s
    "x -> 1 y -> 2 "
   ;; *)

(* Eval test 3 *)

(*
   let x = 3 < 2
*)
let%test _ =
  eval_test
    [ DLet (false, PVar "x", EOp (Less, EConst (CInt 3), EConst (CInt 2))) ]
    "x -> false; "
;;

(* Eval test 4 *)

(*
   let x = (1, 2) < (1, 2, 3)
*)
let%test _ =
  eval_test
    [ DLet
        ( false
        , PVar "x"
        , EOp
            ( Less
            , ETuple [ EConst (CInt 1); EConst (CInt 2) ]
            , ETuple [ EConst (CInt 1); EConst (CInt 2); EConst (CInt 3) ] ) )
    ]
    "Interpretation error: Cannot compare tuples of different size."
;;

(* Eval test 5 *)

(*
   let x =
     let y = 5
     in y
*)
let%test _ =
  eval_test
    [ DLet (false, PVar "x", ELet ([ false, PVar "y", EConst (CInt 5) ], EVar "y")) ]
    "x -> 5; "
;;

(* Eval test 6 *)

(*
   let x =
     let y = 5 in
     let z = 10 in
     y + z
*)
let%test _ =
  eval_test
    [ DLet
        ( false
        , PVar "x"
        , ELet
            ( [ false, PVar "y", EConst (CInt 5); false, PVar "z", EConst (CInt 10) ]
            , EOp (Add, EVar "y", EVar "z") ) )
    ]
    "x -> 15; "
;;

(* Eval test 7 *)

(*
   let x =
     let y = 5 in
     let y = 10 in
     y
*)
let%test _ =
  eval_test
    [ DLet
        ( false
        , PVar "x"
        , ELet
            ( [ false, PVar "y", EConst (CInt 5); false, PVar "y", EConst (CInt 10) ]
            , EVar "y" ) )
    ]
    "x -> 10; "
;;

(* Eval test 8 *)

(*
   let x =
     let y =
       let y = 10 in
       5
     in
     y
*)
let%test _ =
  eval_test
    [ DLet
        ( false
        , PVar "x"
        , ELet
            ( [ ( false
                , PVar "y"
                , ELet ([ false, PVar "y", EConst (CInt 10) ], EConst (CInt 5)) )
              ]
            , EVar "y" ) )
    ]
    "x -> 5; "
;;

(* Eval test 9 *)

(*
   let f x y = x + y
*)
let%test _ =
  eval_test
    [ DLet
        (false, PVar "f", EFun (PVar "x", EFun (PVar "y", EOp (Add, EVar "x", EVar "y"))))
    ]
    "f -> x; "
;;

(* Eval test 10 *)

(*
   let f x y = x + y
   let a = f 1 2
*)
let%test _ =
  eval_test
    [ DLet
        (false, PVar "f", EFun (PVar "x", EFun (PVar "y", EOp (Add, EVar "x", EVar "y"))))
    ; DLet (false, PVar "a", EApp (EApp (EVar "f", EConst (CInt 1)), EConst (CInt 2)))
    ]
    "a -> 3; f -> x; "
;;

(* Eval test 11 *)

(*
   let f x y = x + y
   let kek = f 1
   let lol = kek 2
*)
let%test _ =
  eval_test
    [ DLet
        (false, PVar "f", EFun (PVar "x", EFun (PVar "y", EOp (Add, EVar "x", EVar "y"))))
    ; DLet (false, PVar "kek", EApp (EVar "f", EConst (CInt 1)))
    ; DLet (false, PVar "lol", EApp (EVar "kek", EConst (CInt 2)))
    ]
    "f -> x; kek -> y; lol -> 3; "
;;

(* Eval test 12 *)

(*
   let rec fact n =
   match n with
   | 0 -> 1
   | _ -> n * fact (n + -1)
   let x = fact 3
*)
let%test _ =
  eval_test
    [ DLet
        ( true
        , PVar "fact"
        , EFun
            ( PVar "n"
            , EMatch
                ( EVar "n"
                , [ PConst (CInt 0), EConst (CInt 1)
                  ; ( PWild
                    , EOp
                        ( Mul
                        , EVar "n"
                        , EApp
                            ( EVar "fact"
                            , EOp (Add, EVar "n", EUnOp (Minus, EConst (CInt 1))) ) ) )
                  ] ) ) )
    ; DLet (false, PVar "x", EApp (EVar "fact", EConst (CInt 3)))
    ]
    "fact -> n; x -> 6; "
;;

(* Eval test 13 *)

(*
   effect Failure: int -> int

   let helper x = 1 + perform (Failure x)

   let matcher x = match helper x with
     | effect (Failure s) k -> continue k (1 + s)
     | 3 -> 0 <- success if this one since both helper and effect perform did 1+
     | _ -> 100

   let y = matcher 1 <- must be 3 upon success
*)
let%test _ =
  eval_test
    [ DEffect2 ("Failure", TInt, TInt)
    ; DLet
        ( false
        , PVar "helper"
        , EFun
            ( PVar "x"
            , EOp (Add, EConst (CInt 1), EPerform (EEffect2 ("Failure", EVar "x"))) ) )
    ; DLet
        ( false
        , PVar "matcher"
        , EFun
            ( PVar "x"
            , EMatch
                ( EApp (EVar "helper", EVar "x")
                , [ ( PEffectH (PEffect2 ("Failure", PVar "s"), "k")
                    , EContinue ("k", EOp (Add, EConst (CInt 1), EVar "s")) )
                  ; PConst (CInt 3), EConst (CInt 0)
                  ; PWild, EConst (CInt 100)
                  ] ) ) )
    ; DLet (false, PVar "y", EApp (EVar "matcher", EConst (CInt 1)))
    ]
    "Failure -> Failure eff decl, 2 arg; helper -> x; matcher -> x; y -> 0; "
;;

let%test _ =
  test
    {|
  effect E1: int
  
  let y = E1

  let helper x = 1 + perform (y)

  let res = match helper 1 with
  | effect (E1) k -> continue k (100)
  | 101 -> "correct"
  | _ -> "wrong"

|}
    "E1 -> E1 eff dec, 1 arg; helper -> x; res -> correct; y -> E1 eff; "
;;

let%test _ =
  test
    {|
  effect E: int -> int

  let helper x = match perform (E x) with
  | effect (E s) k -> continue k s*s
  | l -> l

  let res = match perform (E 5) with
  | effect (E s) k -> continue k s*s
  | l -> helper l
|}
    "E -> E eff decl, 2 arg; helper -> x; res -> 625; "
;;
