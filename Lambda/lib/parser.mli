type error = [ `ParsingError of string ]

val pp_error : Format.formatter -> [< `ParsingError of string ] -> unit

(** Main entry of parser *)
val parse : string -> (Ast.name Ast.t, error) result

type dispatch =
  { apps : dispatch -> Ast.name Ast.t Angstrom.t
  ; single : dispatch -> Ast.name Ast.t Angstrom.t
  }

(* A collection of miniparsers *)
val parse_lam : dispatch
