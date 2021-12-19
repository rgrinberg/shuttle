type error =
  | Msg of string
  | Partial

(** Attempts to parse a buffer into a HTTP request. If successful, it returns the parsed
    request and an offset value that indicates the starting point of unconsumed content
    left in the buffer. *)
val parse_request : ?pos:int -> ?len:int -> bytes -> (Request.t * int, error) result

val parse_chunk_length : ?pos:int -> ?len:int -> bytes -> (int64 * int, error) result