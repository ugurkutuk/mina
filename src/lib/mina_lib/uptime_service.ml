(* uptime_service.ml -- proof of uptime for block producers in delegation program *)

open Core_kernel
open Mina_base
open Mina_transition
open Pipe_lib
open Signature_lib

let send_produced_block_at ~logger ~url ~transition_frontier tm =
  let open Async.Deferred.Let_syntax in
  (* give block production a minute *)
  let%bind () = Async.at (Time.add tm Time.Span.minute) in
  match Block_producer.last_block_produced_opt () with
  | None ->
      [%log error] "State hash of last block produced unavailable"
        ~metadata:
          [ ( "expected_block_production_time"
            , `String (Time.to_string_abs ~zone:Time.Zone.utc tm) ) ] ;
      return ()
  | Some state_hash -> (
    match Broadcast_pipe.Reader.peek transition_frontier with
    | None ->
        [%log error]
          "Transition frontier not available to obtain produced block with \
           state hash $state_hash"
          ~metadata:[("state_hash", State_hash.to_yojson state_hash)] ;
        return ()
    | Some tf -> (
      match Transition_frontier.find tf state_hash with
      | None ->
          [%log error]
            "Produced block with state hash $state_hash not found in \
             transition frontier"
            ~metadata:[("state_hash", State_hash.to_yojson state_hash)] ;
          return ()
      | Some breadcrumb -> (
          let {With_hash.data= external_transition; _}, _ =
            Transition_frontier.Breadcrumb.validated_transition breadcrumb
            |> External_transition.Validated.erase
          in
          (* TODO: what's the max size of a serialized block? *)
          let buf = Bin_prot.Common.create_buf 10000000 in
          let len =
            External_transition.Stable.Latest.bin_write_t buf ~pos:0
              external_transition
          in
          let block_string = String.init len ~f:(fun ndx -> buf.{ndx}) in
          (* TODO: HTTPS? *)
          match Base64.encode ~len block_string with
          | Ok base64 -> (
              let json =
                `Assoc
                  [ ( "block_producer"
                    , Public_key.Compressed.to_yojson
                        (External_transition.block_producer external_transition)
                    )
                  ; ("external_transition_base64", `String base64) ]
              in
              match%map
                Cohttp_async.Client.post
                  ~headers:
                    Cohttp.Header.(
                      init () |> fun t -> add t "Accept" "application/json")
                  ~body:
                    (Yojson.Safe.to_string json |> Cohttp_async.Body.of_string)
                  url
              with
              | {status; _}, _body ->
                  if Cohttp.Code.code_of_status status = 200 then
                    [%log info]
                      "Sent block with state hash $state_hash to uptime \
                       server at URL $url"
                      ~metadata:
                        [ ("state_hash", State_hash.to_yojson state_hash)
                        ; ("url", `String (Uri.to_string url)) ]
                  else
                    [%log error]
                      "Failure when sending block with state hash $state_hash \
                       to uptime server at URL $url"
                      ~metadata:
                        [ ("state_hash", State_hash.to_yojson state_hash)
                        ; ("url", `String (Uri.to_string url))
                        ; ( "http_code"
                          , `Int (Cohttp.Code.code_of_status status) )
                        ; ( "http_error"
                          , `String (Cohttp.Code.string_of_status status) ) ] )
          | Error (`Msg err) ->
              [%log error]
                "Could not Base64-encode block with state hash $state_hash"
                ~metadata:
                  [ ("state_hash", State_hash.to_yojson state_hash)
                  ; ("error", `String err) ] ;
              return () ) ) )
