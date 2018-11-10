open Angstrom
open Parsers
open Bigstringaf

(* TODO:
   1. Performance:
   `many` and `choice` together may affect performance, benchmarks are needed

   2. Security:
   unescape

   3. Export inline markup
   @@latex:\paragraph{My paragraph}@@
   @@html:<b>HTML doesn't have \paragraphs</b>@@

*)

module Macro = struct
  type t = {name: string; arguments: string list} [@@deriving yojson]
end

type emphasis = [`Bold | `Italic | `Underline | `Strike_through] * t list [@@deriving yojson]

and footnote_reference = {name: string; definition: t list option} [@@deriving yojson]

and url = File of string | Search of string | Complex of complex [@@deriving yojson]

and complex = {protocol: string; link: string} [@@deriving yojson]

and link = {url: url; label: t list} [@@deriving yojson]

(** {2 Cookies} *)

(** Cookies are a way to indicate the progress of a task.
    They can be of two form : percentage or absolute value *)
and stats_cookie =
    Percent of int
  | Absolute of int * int  (** current, max *)
[@@deriving yojson]

and latex_fragment = Inline of string | Displayed of string [@@deriving yojson]

and clock_item = Started of Timestamp.t | Stopped of Timestamp.range

and timestamp =
    Scheduled of Timestamp.t
  | Deadline of Timestamp.t
  | Date of Timestamp.t
  | Closed of Timestamp.t
  | Clock of clock_item
  | Range of Timestamp.range
[@@deriving yojson]

and t =
    Emphasis of emphasis
  | Break_Line
  | Verbatim of string
  | Code of string
  | Plain of string
  | Link of link
  | Target of string
  | Subscript of t list
  | Superscript of t list
  | Footnote_Reference of footnote_reference
  | Cookie of stats_cookie
  | Latex_Fragment of latex_fragment
  | Macro of Macro.t
  | Entity of Entity.t
  | Timestamp of timestamp
  | Radio_Target of string
  | Export_Snippet of string * string
[@@deriving yojson]

(* emphasis *)
let delims =
  [ ('*', ('*', `Bold))
  ; ('_', ('_', `Underline))
  ; ('/', ('/', `Italic))
  ; ('+', ('+', `Strike_through))
  ; ('~', ('~', `Code))
  ; ('=', ('=', `Verbatim))
  ; ('[', (']', `Bracket))
  ; ('<', ('>', `Chev))
  ; ('{', ('}', `Brace))
  ; ('(', (')', `Paren)) ]

let link_delims = ['['; ']'; '<'; '>'; '{'; '}'; '('; ')'; '*'; '$']

let prev = ref None

let emphasis_token c =
  let blank_before_delimiter = ref false in
  peek_char_fail
  >>= fun x ->
  if is_space x then fail "space before token"
  else
    take_while1 (function
        | x when x = c -> (
            match !prev with
            | Some x ->
              if x = ' ' then blank_before_delimiter := true ;
              false
            | None -> false )
        | '\r' | '\n' -> false
        | x ->
          prev := Some x ;
          true )
    >>= fun s ->
    let blank_before = !blank_before_delimiter in
    blank_before_delimiter := false ;
    if blank_before then fail "emphasis_token" else return s

let between c =
  between_char c c (emphasis_token c)
  >>= fun s ->
  peek_char
  >>= function
  | None -> return s
  | Some c -> (
      match c with
      | '\n' | '\r' | ' ' | '\t' | '.' | ',' | '!' | '?' | '"' | '\'' | ')' | '-' | ':' | ';' | '[' | '}'
        -> return s
      | _ -> fail "between" )

let bold =
  between '*'
  >>= fun s -> return (Emphasis (`Bold, [Plain s])) <?> "Inline bold"

let underline =
  between '_'
  >>= fun s -> return (Emphasis (`Underline, [Plain s])) <?> "Inline underline"

let italic =
  between '/'
  >>= fun s -> return (Emphasis (`Italic, [Plain s])) <?> "Inline italic"

let strike_through =
  between '+'
  >>= fun s ->
  return (Emphasis (`Strike_through, [Plain s])) <?> "Inline strike_through"

(* '=', '~' verbatim *)
let verbatim =
  between '=' >>= fun s -> return (Verbatim s) <?> "Inline verbatim"

let code = between '~' >>= fun s -> return (Code s) <?> "Inline code"

(* TODO: optimization *)
let plain_delims = ['*'; '_'; '/'; '+'; '~'; '='; '['; '<'; '{'; '$']
let in_plain_delims c =
  List.exists (fun d -> c = d) plain_delims

let plain =
  (scan1 false (fun state c ->
       if (not state && (c = '_' || c = '^')) then
         Some true
       else if (non_eol c && not (in_plain_delims c) ) then
         Some true
       else
         None)
   >>= fun (s, state) ->
   return (Plain s))
  <|>
  (line >>= fun s -> return (Plain s))

let emphasis =
  peek_char_fail >>= function
  | '*' -> bold
  | '_' -> underline
  | '/' -> italic
  | '+' -> strike_through
  | _ -> fail "Inline emphasis"

let nested_emphasis =
  let rec aux_nested_emphasis = function
    | Plain s ->
      Plain s
    | Emphasis (typ, [Plain s]) as e ->
      let parser = (many1 (choice [emphasis; plain])) in
      (match parse_string parser s with
       | Ok [Plain _] -> e
       | Ok result -> Emphasis (typ,
                                List.map aux_nested_emphasis result)
       | Error error -> e)
    | _ ->
      failwith "nested_emphasis" in
  emphasis >>= fun e ->
  return (aux_nested_emphasis e)

let breakline = eol >>= fun _ -> fail "breakline"

let target =
  between_string "<<" ">>"
    ( take_while1 (function '>' | '\r' | '\n' -> false | _ -> true)
      >>= fun s -> return @@ Target s )

let concat_plains inlines =
  let l = List.fold_left (fun acc inline ->
      match inline with
      | Plain s ->
        (match acc with
         | [] -> [Plain s]
         | (Plain s') :: tl ->
           (Plain (s' ^ s)) :: tl
         | _ ->
           Plain s :: acc)
      | other -> other :: acc
    ) [] inlines in
  List.rev l


(* \alpha *)
let entity =
  char '\\' *> take_while1 is_letter
  >>| fun s ->
  try
    let entity = Entity.find s in
    Entity entity
  with Not_found ->
    Plain s

(* foo_{bar}, foo^{bar} *)
let subscript, superscript =
  let p = many1 (choice [nested_emphasis; plain; entity]) in
  let gen s f =
    string s *> take_while1 (fun c -> non_space c && c <> '}')
    <* char '}' >>| fun s ->
    match parse_string p s with
    | Ok result -> f result
    | Error e -> f [Plain s]
  in
  ( gen "_{" (fun x -> Subscript x)
  , gen "^{" (fun x -> Superscript x) )

let statistics_cookie =
  between_char '[' ']'
    (take_while1 (fun c ->
         if c = '/' || c = '%' || Prelude.is_digit c then true else false ))
  >>= fun s ->
  try let cookie = Scanf.sscanf s "%d/%d" (fun n n' -> Absolute (n, n')) in
    return (Cookie cookie)
  with _ ->
  try let cookie = Scanf.sscanf s "%d%%" (fun n -> Percent n) in
    return (Cookie cookie)
  with _ ->
    fail "statistics_cookie"

(*
   1. $content$, TeX delimiters for inline math.
   2. \( content \), LaTeX delimiters for inline math.
   3. $$content$$, TeX delimiters for displayed math.
   4. \[ content \], LaTeX delimiters for displayed math.

   If $a^2=b$ and \( b=2 \), then the solution must be
   either $$ a=+\sqrt{2} $$ or \[ a=-\sqrt{2} \].

*)
(*
   latex block.

   \begin{equation}
   x=\sqrt{b}
   \end{equation}

*)
let latex_fragment =
  any_char
  >>= function
  | '$' ->
    any_char
    >>= fun c ->
    if c == '$' then
      (* displayed math *)
      take_while1 (fun x -> x <> '$')
      <* string "$$"
      >>| fun s -> Latex_Fragment (Displayed s)
    else
      (* inline math *)
      take_while1 (fun x -> x <> '$')
      <* char '$'
      >>| fun s -> Latex_Fragment (Inline s)
  | '\\' -> (
      any_char
      >>= function
      | '[' ->
        (* displayed math *)
        end_string "\\]" (fun s -> Latex_Fragment (Displayed s))
      | '(' ->
        (* inline math *)
        end_string "\\)" (fun s -> Latex_Fragment (Inline s))
      | _ -> fail "latex fragment \\" )
  | _ -> fail "latex fragment"

(*
   Define: #+MACRO: demo =$1= ($1)
   Usage:  {{{demo(arg1, arg2, ..., argn)}}}
*)
let macro =
  lift2
    (fun name arguments ->
       let arguments = String.split_on_char ',' arguments in
       let arguments = List.map String.trim arguments in
       Macro {name; arguments} )
    (string "{{{" *> take_while1 (fun c -> c <> '(') <* char '(')
    (take_while1 (fun c -> c <> ')') <* string ")}}}")

let date_time close_char ~active typ =
  let open Timestamp in
  let space = satisfy is_space in
  let non_spaces = take_while1 (fun c -> non_space c && c <> close_char) in
  let date_parser = non_spaces <* space >>| fun s -> parse_date s in
  let day_name_parser = letters in
  (* time_or_repeat_1 *)
  let tr1_parser = optional (space *> non_spaces) in
  (* time_or_repeat_2 *)
  let tr2_parser = optional (space *> non_spaces) in
  date_parser >>= function
  | None -> fail "date parser"
  | Some date ->
    lift3
      (fun _day_name time_or_repeat tr2 ->
         let date, time, repetition =
           match time_or_repeat with
           | None -> (date, None, None)
           | Some s -> (
               match tr2 with
               | None -> (
                   match s.[0] with
                   | ('+' | '.') as c -> (* repeat *)
                     repetition_parser s date None c
                   | _ ->
                     (* time *)
                     let time = parse_time s in
                     (date, time, None) )
               | Some s' ->
                 let time = parse_time s in
                 repetition_parser s' date time s'.[0] )
         in
         match typ with
         | "Scheduled" -> Timestamp (Scheduled {date; time; repetition; active})
         | "Deadline" -> Timestamp (Deadline {date; time; repetition; active})
         | "Closed" -> Timestamp (Closed {date; time; repetition; active})
         | "Clock" -> Timestamp (Clock (Started {date; time; repetition; active}))
         | _ -> Timestamp (Date {date; time; repetition; active}) )
      day_name_parser tr1_parser tr2_parser
    <* char close_char

(* DEADLINE: <2018-10-16 Tue>
   DEADLINE: <2008-02-10 Sun +1w>
   DEADLINE: <2008-02-10 Sun ++1w> (* still Sunday, forget old ones *)
   DEADLINE: <2005-11-01 Tue .+1m> (* from today, not exactly Tuesday *)
   <2018-10-16 Tue 21:20>
   <2007-05-16 Wed 12:30 +1w>

   Not supported:
   range_1: 2006-11-02 Thu 20:00-22:00
*)

let general_timestamp =
  let active_parser typ = date_time '>' ~active:true typ in
  let closed_parser typ = date_time ']' ~active:false typ in
  let parse rest typ =
    (* scheduled *)
    string rest *> spaces *> any_char
    >>= function
    | '<' -> active_parser typ
    | '[' -> closed_parser typ
    | _ -> fail "general_timestamp"
  in
  spaces *> any_char
  >>= function
  | '<' -> active_parser "Date"
  | '[' -> closed_parser "Date"
  | 'S' -> parse "CHEDULED:" "Scheduled"
  | 'C' -> (
      take 3
      >>= function
      | "LOS" -> parse "ED:" "Closed"
      | "LOC" -> parse "K:" "Clock"
      | _ -> fail "general_timestamp C" )
  | 'D' -> parse "EADLINE:" "Deadline"
  | _ -> fail "general_timestamp"

(* example: <2004-08-23 Mon>--<2004-08-26 Thu> *)
(* clock:
 *** Clock Started
     CLOCK: [2018-09-25 Tue 13:49]

 *** DONE Clock stopped
    CLOSED: [2018-09-25 Tue 13:51]
    CLOCK: [2018-09-25 Tue 13:50] *)
let range =
  let extract_time t =
    match t with
    | Timestamp t -> (
        match t with
        | Date t | Scheduled t | Deadline t | Closed t -> t
        | _ -> failwith "illegal timestamp" )
    | _ -> failwith "illegal timestamp"
  in
  lift3
    (fun clock t1 t2 ->
       let t1 = extract_time t1 in
       let t2 = extract_time t2 in
       if clock = "CLOCK:" then
         Timestamp (Clock (Stopped {start= t1; stop= t2}))
       else
         Timestamp (Range {start= t1; stop= t2}))
    (spaces *> string "CLOCK:" <* spaces)
    (general_timestamp <* string "--")
    general_timestamp

let timestamp =
  range <|> general_timestamp

(* link *)
(* 1. [[url][label]] *)
(* 2. [[search]] *)
let link =
  let url_part =
    string "[[" *> take_while1 (fun c -> c <> ']') <* optional (string "][")
  in
  let label_part = take_while (fun c -> c <> ']') <* string "]]" in
  lift2
    (fun url label ->
       let url =
         if label = "" then Search url
         else if url.[0] = '/' || url.[0] = '.' then File url
         else
           try
             Scanf.sscanf url "%[^:]:%[^\n]" (fun protocol link ->
                 Complex {protocol; link} )
           with _ -> Search url
       in
       let parser = (many1 (choice [nested_emphasis; latex_fragment; entity; code; subscript; superscript; plain])) in
       let label = match parse_string parser label with
           Ok result -> concat_plains result
         | Error e -> [Plain label] in
       Link {label; url} )
    url_part label_part

(* complex link *)
(* :// *)
let link_inline =
  let protocol_part = take_while1 is_letter <* string "://" in
  let link_part =
    take_while1 (fun c ->
        non_space c && List.for_all (fun c' -> c <> c') link_delims )
  in
  lift2
    (fun protocol link ->
       Link
         { label= [Plain (protocol ^ "://" ^ link)]
         ; url= Complex {protocol; link= "//" ^ link} } )
    protocol_part link_part

let id = ref 0

let footnote_inline_definition definition =
  let parser = (many1 (choice [link; link_inline; target; nested_emphasis; latex_fragment; entity; code; subscript; superscript; plain])) in
  match parse_string parser definition with
  | Ok result ->
    let result = concat_plains result in
    result
  | Error error ->
    [Plain definition]

let latex_footnote =
  string "[fn::" *> take_while1 (fun c -> c <> ']' && non_eol c)
  <* char ']' >>| fun definition ->
  Footnote_Reference {name = ""; definition= Some (footnote_inline_definition definition)}

let footnote_reference =
  latex_footnote
  <|>
  let name_part =
    string "[fn:" *> take_while1 (fun c -> c <> ':' && c <> ']' && non_eol c)
    <* optional (char ':') in
  let definition_part = take_while (fun c -> c <> ']' && non_eol c) <* char ']' in
  lift2
    (fun name definition ->
       let name =
         if name = "" then (
           incr id ;
           "_anon_" ^ string_of_int !id )
         else name
       in
       if definition = "" then Footnote_Reference {name; definition= None}
       else Footnote_Reference {name; definition= Some (footnote_inline_definition definition)} )
    name_part definition_part

(* TODO: configurable *)
let inline_choices =
  choice
    [ latex_fragment            (* '$' '\' *)
    ; timestamp                 (* '<' '[' 'S' 'C' 'D'*)
    ; entity                    (* '\' *)
    ; macro                     (* '{' *)
    ; statistics_cookie         (* '[' *)
    ; footnote_reference        (* 'f', fn *)
    ; link                      (* '[' [[]] *)
    ; link_inline               (*  *)
    ; target                    (* "<<" *)
    ; verbatim                  (*  *)
    ; code                      (* '=' *)
    ; breakline                 (* '\n' *)
    ; nested_emphasis
    ; subscript                 (* '_' "_{" *)
    ; superscript               (* '^' "^{" *)
    ; plain ]

let parse =
  fix (fun inline ->
      many1 inline_choices >>| fun l ->
      concat_plains l)

let rec ascii = function
  | Footnote_Reference ref -> Option.map_default asciis "" ref.definition
  | Link l -> asciis l.label
  | Emphasis (_, t) -> asciis t
  | Subscript l | Superscript l -> asciis l
  | Latex_Fragment (Inline s) | Plain s | Verbatim s -> s
  | Entity e -> e.Entity.unicode
  | _ -> ""


and asciis l = String.concat "" (List.map ascii l)
