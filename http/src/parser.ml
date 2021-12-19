external unsafe_memchr
  :  bytes
  -> int
  -> char
  -> int
  -> int
  = "shuttle_parser_bytes_memchr_stub"
  [@@noalloc]

module Source = struct
  type t =
    { buffer : bytes
    ; mutable pos : int
    ; min_off : int
    ; upper_bound : int
    }

  let of_bytes ?pos ?len buffer =
    let buf_len = Bytes.length buffer in
    let pos = Option.value pos ~default:0 in
    if pos < 0 || pos > buf_len
    then
      invalid_arg
        (Printf.sprintf
           "Shuttle_http.Parser.Source.of_bigstring: Invalid offset %d. Buffer length: %d"
           pos
           buf_len);
    let len = Option.value len ~default:(buf_len - pos) in
    if len < 0 || pos + len > buf_len
    then
      invalid_arg
        (Printf.sprintf
           "Shuttle_http.Parser.Source.of_bigstring: Invalid len %d. offset: %d, \
            buffer_length: %d, requested_length: %d"
           len
           pos
           buf_len
           (pos + len));
    { buffer; pos; min_off = pos; upper_bound = pos + len }
  ;;

  let get t idx =
    if idx < 0 || t.pos + idx >= t.upper_bound
    then invalid_arg "Shuttle_http.Parser.Source.get: Index out of bounds";
    Bytes.unsafe_get t.buffer (t.pos + idx)
  ;;

  let advance t count =
    if count < 0 || t.pos + count > t.upper_bound
    then
      invalid_arg
        (Printf.sprintf
           "Shuttle_http.Parser.Source.advance: Index out of bounds. Requested count: %d"
           count);
    t.pos <- t.pos + count
  ;;

  let length t = t.upper_bound - t.pos

  let to_string t ~pos ~len =
    if pos < 0
       || t.pos + pos >= t.upper_bound
       || len < 0
       || t.pos + pos + len > t.upper_bound
    then
      invalid_arg
        (Format.asprintf
           "Shuttle_http.Parser.Source.substring: Index out of bounds., Requested off: \
            %d, len: %d"
           pos
           len);
    Bytes.sub_string t.buffer (t.pos + pos) len
  ;;

  let consumed t = t.pos - t.min_off

  let index t ch =
    let res = unsafe_memchr t.buffer t.pos ch (length t) in
    if res = -1 then -1 else res - t.pos
  ;;

  let for_all t ~pos ~len ~f =
    if pos < 0
       || t.pos + pos >= t.upper_bound
       || len < 0
       || t.pos + pos + len > t.upper_bound
    then
      invalid_arg
        (Format.asprintf
           "Shuttle_http.Parser.Source.substring: Index out of bounds. Requested off: \
            %d, len: %d"
           pos
           len);
    let idx = ref pos in
    while !idx < len && f (get t !idx) do
      incr idx
    done;
    if !idx = len then true else false
  ;;
end

type error =
  | Msg of string
  | Partial

type 'a parser = { run : Source.t -> ('a, error) result }

let return x = { run = (fun _source -> Ok x) }
let fail msg = { run = (fun _source -> Error (Msg msg)) }
let ( >>=? ) t f = Result.bind t f
let ( >>= ) t f = { run = (fun source -> t.run source >>=? fun v -> (f v).run source) }

let map4 fn a b c d =
  { run =
      (fun source ->
        a.run source
        >>=? fun res_a ->
        b.run source
        >>=? fun res_b ->
        c.run source
        >>=? fun res_c -> d.run source >>=? fun res_d -> Ok (fn res_a res_b res_c res_d))
  }
;;

let ( *> ) a b = { run = (fun source -> a.run source >>=? fun _res_a -> b.run source) }

let ( <* ) a b =
  { run =
      (fun source ->
        a.run source >>=? fun res_a -> b.run source >>=? fun _res_b -> Ok res_a)
  }
;;

let string str =
  let run source =
    let len = String.length str in
    if Source.length source < len
    then Error Partial
    else (
      let rec aux idx =
        if idx = len
        then (
          Source.advance source len;
          Ok str)
        else if Source.get source idx = String.unsafe_get str idx
        then aux (idx + 1)
        else Error (Msg (Printf.sprintf "Could not match: %S" str))
      in
      aux 0)
  in
  { run }
;;

let any_char =
  let run source =
    if Source.length source = 0
    then Error Partial
    else (
      let c = Source.get source 0 in
      Source.advance source 1;
      Ok c)
  in
  { run }
;;

let eol = string "\r\n"

(* token = 1*tchar tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "^"
   / "_" / "`" / "|" / "~" / DIGIT / ALPHA ; any VCHAR, except delimiters *)

let is_tchar = function
  | '0' .. '9'
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '!'
  | '#'
  | '$'
  | '%'
  | '&'
  | '\''
  | '*'
  | '+'
  | '-'
  | '.'
  | '^'
  | '_'
  | '`'
  | '|'
  | '~' -> true
  | _ -> false
;;

let token =
  let run source =
    let pos = Source.index source ' ' in
    if pos = -1
    then Error Partial
    else (
      let res = Source.to_string source ~pos:0 ~len:pos in
      Source.advance source (pos + 1);
      Ok res)
  in
  { run }
;;

let meth =
  token
  >>= fun token ->
  match Meth.of_string token with
  | Some m -> return m
  | None -> fail (Printf.sprintf "Unexpected HTTP verb %S" token)
;;

let version =
  string "HTTP/1." *> any_char
  >>= (function
        | '1' -> return Version.v1_1
        | '0' -> return { Version.major = 1; minor = 0 }
        | _ -> fail "Invalid http version")
  <* eol
;;

let header =
  let run source =
    let pos = Source.index source ':' in
    if pos = -1
    then Error Partial
    else if pos = 0
    then Error (Msg "Invalid header: Empty header key")
    else if Source.for_all source ~pos:0 ~len:pos ~f:is_tchar
    then (
      let key = Source.to_string source ~pos:0 ~len:pos in
      Source.advance source (pos + 1);
      while Source.length source > 0 && Source.get source 0 = ' ' do
        Source.advance source 1
      done;
      let pos = Source.index source '\r' in
      if pos = -1
      then Error Partial
      else (
        let v = Source.to_string source ~pos:0 ~len:pos in
        Source.advance source pos;
        Ok (key, String.trim v)))
    else Error (Msg "Invalid Header Key")
  in
  { run } <* eol
;;

let headers =
  let run source =
    let rec loop acc =
      let len = Source.length source in
      if len > 0 && Source.get source 0 = '\r'
      then eol.run source >>=? fun _ -> Ok (Headers.of_list acc)
      else header.run source >>=? fun v -> loop (v :: acc)
    in
    loop []
  in
  { run }
;;

let chunk_length =
  let run source =
    let ( lsl ) = Int64.shift_left in
    let ( lor ) = Int64.logor in
    let length = ref 0L in
    let stop = ref false in
    let state = ref `Ok in
    let count = ref 0 in
    let processing_chunk = ref true in
    let in_chunk_extension = ref false in
    while not !stop do
      if Source.length source = 0
      then (
        stop := true;
        state := `Partial)
      else if !count = 16 && not !in_chunk_extension
      then (
        stop := true;
        state := `Chunk_too_big)
      else (
        let ch = Source.get source 0 in
        Source.advance source 1;
        incr count;
        match ch with
        | '0' .. '9' as ch when !processing_chunk ->
          let curr = Int64.of_int (Char.code ch - Char.code '0') in
          length := (!length lsl 4) lor curr
        | 'a' .. 'f' as ch when !processing_chunk ->
          let curr = Int64.of_int (Char.code ch - Char.code 'a' + 10) in
          length := (!length lsl 4) lor curr
        | 'A' .. 'F' as ch when !processing_chunk ->
          let curr = Int64.of_int (Char.code ch - Char.code 'A' + 10) in
          length := (!length lsl 4) lor curr
        | ';' when not !in_chunk_extension ->
          in_chunk_extension := true;
          processing_chunk := false
        | ('\t' | ' ') when !processing_chunk -> processing_chunk := false
        | ('\t' | ' ') when (not !in_chunk_extension) && not !processing_chunk -> ()
        | '\r' ->
          if Source.length source = 0
          then (
            stop := true;
            state := `Partial)
          else if Source.get source 0 = '\n'
          then (
            Source.advance source 1;
            stop := true)
          else (
            stop := true;
            state := `Expected_newline)
        | _ when !in_chunk_extension ->
          (* Chunk extensions aren't very common, see:
             https://tools.ietf.org/html/rfc7230#section-4.1.1 Chunk extensions aren't
             pre-defined, and they are specific to invidividual connections. In the future
             we might surface these to the user somehow, but for now we will ignore any
             extensions. TODO: Should there be any limit on the size of chunk extensions
             we parse? We might want to error if a request contains really large chunk
             extensions. *)
          ()
        | ch ->
          stop := true;
          state := `Invalid_char ch)
    done;
    match !state with
    | `Ok -> Ok !length
    | `Partial -> Error Partial
    | `Expected_newline -> Error (Msg "Expected_newline")
    | `Chunk_too_big -> Error (Msg "Chunk size is too large")
    | `Invalid_char ch ->
      Error (Msg (Printf.sprintf "Invalid chunk_length character %C" ch))
  in
  { run }
;;

let request =
  map4
    (fun meth path version headers -> Request.create ~version ~headers meth path)
    meth
    token
    version
    headers
;;

let run_parser ?pos ?len buf p =
  let source = Source.of_bytes ?pos ?len buf in
  p.run source >>=? fun v -> Ok (v, Source.consumed source)
;;

let parse_request ?pos ?len buf = run_parser ?pos ?len buf request
let parse_chunk_length ?pos ?len buf = run_parser ?pos ?len buf chunk_length