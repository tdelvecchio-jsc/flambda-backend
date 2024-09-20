(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*      KC Sivaramakrishnan, Indian Institute of Technology, Madras       *)
(*                 Stephen Dolan, University of Cambridge                 *)
(*                   Tom Kelly, OCaml Labs Consultancy                    *)
(*                                                                        *)
(*   Copyright 2019 Indian Institute of Technology, Madras                *)
(*   Copyright 2014 University of Cambridge                               *)
(*   Copyright 2021 OCaml Labs Consultancy Ltd                            *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

open! Stdlib

[@@@ocaml.flambda_o3]

external runtime5 : unit -> bool @@ portable = "%runtime5"

module Runtime_4 = struct
  module DLS = struct

    let unique_value = Obj.repr (ref 0)
    let state = ref (Array.make 8 unique_value)

    let init () = ()

    type password = unit
    type 'a key = int * (unit -> 'a)

    let initial_password = ()
    let with_password f = f ()

    let key_counter = ref 0

    let new_key ?split_from_parent:_ init_orphan =
      let idx = !key_counter in
      key_counter := idx + 1;
      (idx, init_orphan)

    let new_key_safe ?split_from_parent:_ init_orphan = new_key init_orphan

    (* If necessary, grow the current domain's local state array such that [idx]
    * is a valid index in the array. *)
    let maybe_grow idx =
      let st = !state in
      let sz = Array.length st in
      if idx < sz then st
      else begin
        let rec compute_new_size s =
          if idx < s then s else compute_new_size (2 * s)
        in
        let new_sz = compute_new_size sz in
        let new_st = Array.make new_sz unique_value in
        Array.blit st 0 new_st 0 sz;
        state := new_st;
        new_st
      end

    let set' () (idx, _init) x =
      let st = maybe_grow idx in
      (* [Sys.opaque_identity] ensures that flambda does not look at the type of
      * [x], which may be a [float] and conclude that the [st] is a float array.
      * We do not want OCaml's float array optimisation kicking in here. *)
      st.(idx) <- Obj.repr (Sys.opaque_identity x)

    let set key x = set' () key x

    let get' () (idx, init) =
      let st = maybe_grow idx in
      let v = st.(idx) in
      if v == unique_value then
        let v' = Obj.repr (init ()) in
        st.(idx) <- (Sys.opaque_identity v');
        Obj.magic v'
      else Obj.magic v

    let get key = get' () key
  end

  (******** Callbacks **********)

  (* first spawn, domain startup and at exit functionality *)
  let first_domain_spawned = Atomic.make false

  let first_spawn_function = ref (fun () -> ())

  let before_first_spawn f =
    if Atomic.get_safe first_domain_spawned then
      raise (Invalid_argument "first domain already spawned")
    else begin
      let old_f = !first_spawn_function in
      let new_f () = old_f (); f () in
      first_spawn_function := new_f
    end

  let at_exit_key = DLS.new_key (fun () -> (fun () -> ()))

  let at_exit' () f =
    let old_exit : unit -> unit = DLS.get at_exit_key in
    let new_exit () =
      (* The domain termination callbacks ([at_exit]) are run in
        last-in-first-out (LIFO) order in order to be symmetric with the domain
        creation callbacks ([at_each_spawn]) which run in first-in-fisrt-out
        (FIFO) order. *)
      f (); old_exit ()
    in
    DLS.set at_exit_key new_exit

  let at_exit_safe = at_exit' ()

  let at_exit = at_exit_safe

  let do_at_exit () =
    let f : unit -> unit = DLS.get at_exit_key in
    f ()

  (* Unimplemented functions *)
  let not_implemented () =
    failwith "Multi-domain functionality not supported in runtime4"
  type !'a t
  type id = int
  let spawn _ = not_implemented ()
  let spawn_safe _ = not_implemented ()
  let spawn_with_dls _ = not_implemented ()
  let join _ = not_implemented ()
  let get_id _ = not_implemented ()
  let self () = not_implemented ()
  let cpu_relax () = not_implemented ()
  let is_main_domain () = not_implemented ()
  let recommended_domain_count () = not_implemented ()
end

module Runtime_5 = struct
  module Raw = struct
    (* Low-level primitives provided by the runtime *)
    type t = private int

    (* The layouts of [state] and [term_sync] are hard-coded in
      [runtime/domain.c] *)

    type 'a state =
      | Running
      | Finished of ('a, exn) result [@warning "-unused-constructor"]

    type 'a term_sync = {
      (* protected by [mut] *)
      mutable state : 'a state [@warning "-unused-field"] ;
      mut : Mutex.t ;
      cond : Condition.t ;
    }

    external spawn : (unit -> 'a) -> 'a term_sync -> t @@ portable
      = "caml_domain_spawn"
    external self : unit -> t @@ portable
      = "caml_ml_domain_id" [@@noalloc]
    external cpu_relax : unit -> unit @@ portable
      = "caml_ml_domain_cpu_relax"
    external get_recommended_domain_count: unit -> int @@ portable
      = "caml_recommended_domain_count" [@@noalloc]
  end

  let cpu_relax () = Raw.cpu_relax ()

  type id = Raw.t

  type 'a t = {
    domain : Raw.t;
    term_sync : 'a Raw.term_sync;
  }

  module DLS = struct

    module Obj_opt : sig
      type t : value mod portable uncontended
      val none : t @@ portable
      val some : 'a -> t @@ portable
      val is_some : t -> bool @@ portable

      (** [unsafe_get obj] may only be called safely
          if [is_some] is true.

          [unsafe_get (some v)] is equivalent to
          [Obj.obj (Obj.repr v)]. *)
      val unsafe_get : t -> 'a @@ portable
    end = struct
      type t : value mod portable uncontended = O of Obj.t
      let none : t = O (Obj.repr (ref 0))
      let some v = O (Obj.repr v)
      let is_some obj =
        let O obj = obj
        and O none = none in
        (obj != none)
      let unsafe_get (O obj) = Obj.obj obj
    end

    type dls_state = Obj_opt.t array

    external get_dls_state : unit -> dls_state @@ portable = "%dls_get"

    external set_dls_state : dls_state -> unit @@ portable =
      "caml_domain_dls_set" [@@noalloc]

    external compare_and_set_dls_state : dls_state -> dls_state -> bool @@ portable =
      "caml_domain_dls_compare_and_set" [@@noalloc]

    let create_dls () =
      let st = Array.make 8 Obj_opt.none in
      set_dls_state st

    let init () = create_dls ()

    type password = unit

    type 'a key : value mod portable uncontended = K of int * (password -> 'a) @@ portable

    let initial_password = ()
    let with_password f = f ()

    let key_counter = Atomic.make 0

    type key_initializer =
      KI: 'a key * ('a -> (password -> 'a) @ portable) @@ portable -> key_initializer

    (* CR tdelvecchio: Remove when we have [with]. *)
    type key_initializer_list : value mod portable uncontended = KIs of key_initializer list

    let parent_keys = Atomic.make (KIs [])

    let rec add_parent_key ki =
      let KIs l = Atomic.get_safe parent_keys in
      if not (Atomic.compare_and_set parent_keys (KIs l) (KIs (ki :: l)))
      then add_parent_key ki

    let new_key_safe ?split_from_parent init_orphan =
      let idx = Atomic.fetch_and_add key_counter 1 in
      let k = K (idx, init_orphan) in
      begin match split_from_parent with
      | None -> ()
      | Some split -> add_parent_key (KI(k, split))
      end;
      k

    let new_key ?split_from_parent init_orphan =
      let split_from_parent = Obj.magic_portable split_from_parent in
      let init_orphan = Obj.magic_portable init_orphan in
      let split_from_parent =
        match split_from_parent with
        | None -> None
        | Some f ->
          Some (fun x -> Obj.magic_portable (fun (_ : password) -> f x))
      in
      new_key_safe ?split_from_parent init_orphan

    (* If necessary, grow the current domain's local state array such that [idx]
    * is a valid index in the array. *)
    let rec maybe_grow idx =
      (* CR ocaml 5 all-runtime5: remove this hack which is here to stop
        the backend seeing the dls_get operation and failing on runtime4 *)
      if not (runtime5 ()) then assert false else
      (* end of hack *)
      let st = get_dls_state () in
      let sz = Array.length st in
      if idx < sz then st
      else begin
        let rec compute_new_size s =
          if idx < s then s else compute_new_size (2 * s)
        in
        let new_sz = compute_new_size sz in
        let new_st = Array.make new_sz Obj_opt.none in
        Array.blit st 0 new_st 0 sz;
        (* We want a implementation that is safe with respect to
          single-domain multi-threading: retry if the DLS state has
          changed under our feet.
          Note that the number of retries will be very small in
          contended scenarios, as the array only grows, with
          exponential resizing. *)
        if compare_and_set_dls_state st new_st
        then new_st
        else maybe_grow idx
      end

    let set' (type a) () (K (idx, _init)) (x : a) =
      let st = maybe_grow idx in
      (* [Sys.opaque_identity] ensures that flambda does not look at the type of
      * [x], which may be a [float] and conclude that the [st] is a float array.
      * We do not want OCaml's float array optimisation kicking in here. *)
      st.(idx) <- Obj_opt.some (Sys.opaque_identity x)

    let set k x = set' () k x

    let[@inline never] array_compare_and_set a i oldval newval =
      (* Note: we cannot use [@poll error] due to the
        allocations on a.(i) in the Double_array case. *)
      let curval = a.(i) in
      if curval == oldval then (
        Array.unsafe_set a i newval;
        true
      ) else false

    let get' (type a) () (K (idx, init)) : a =
      let st = maybe_grow idx in
      let obj = st.(idx) in
      if Obj_opt.is_some obj
      then (Obj_opt.unsafe_get obj : a)
      else begin
        let v : a = init () in
        let new_obj = Obj_opt.some (Sys.opaque_identity v) in
        (* At this point, [st] or [st.(idx)] may have been changed
          by another thread on the same domain.

          If [st] changed, it was resized into a larger value,
          we can just reuse the new value.

          If [st.(idx)] changed, we drop the current value to avoid
          letting other threads observe a 'revert' that forgets
          previous modifications. *)
        let st = get_dls_state () in
        if array_compare_and_set st idx obj new_obj
        then v
        else begin
          (* if st.(idx) changed, someone must have initialized
            the key in the meantime. *)
          let updated_obj = st.(idx) in
          if Obj_opt.is_some updated_obj
          then (Obj_opt.unsafe_get updated_obj : a)
          else assert false
        end
      end

    let get k = get' () k

    type key_value = KV : 'a key * 'a -> key_value

    let get_initial_keys () : key_value list =
      let (KIs parent_keys) : key_initializer_list = Atomic.get_safe parent_keys in
      List.map
        (fun (KI (k, split)) -> KV (k, ((split (get k)) ())))
        parent_keys

    let set_initial_keys (l: key_value list) =
      List.iter (fun (KV (k, v)) -> set k v) l
  end

  (******** Identity **********)

  let get_id { domain; _ } = domain

  let self () = Raw.self ()

  let is_main_domain () = (self () :> int) = 0

  (******** Callbacks **********)

  (* first spawn, domain startup and at exit functionality *)
  let first_domain_spawned = Atomic.make false

  type f : value mod portable = F of (unit -> unit) @@ portable

  let first_spawn_function = Atomic.make (F (fun () -> ()))

  let before_first_spawn f =
    if Atomic.get_safe first_domain_spawned then
      raise (Invalid_argument "first domain already spawned")
    else begin
      (* We are guaranteed to still only have one domain, so this is safe. *)
      let f = Obj.magic_portable f in
      let F old_f = Atomic.get_safe first_spawn_function in
      let new_f () = old_f (); f () in
      Atomic.set first_spawn_function (F new_f)
    end

  let do_before_first_spawn () =
    if not (Atomic.get_safe first_domain_spawned) then begin
      Atomic.set first_domain_spawned true;
      let F f = Atomic.get_safe first_spawn_function in
      f ();
      (* Release the old function *)
      Atomic.set first_spawn_function (F (fun () -> ()))
    end


  let at_exit_key = DLS.new_key (fun () -> (fun () -> ()))

  let at_exit' () f =
    let old_exit : unit -> unit = DLS.get at_exit_key in
    let new_exit () =
      f (); old_exit ()
    in
    DLS.set at_exit_key new_exit

  let at_exit_safe = at_exit' ()

  let at_exit = at_exit_safe

  let do_at_exit () =
    let f : unit -> unit = DLS.get at_exit_key in
    f ()

  let _ = Stdlib.set_do_domain_local_at_exit do_at_exit

  (******* Creation and Termination ********)

  let spawn_with_dls f =
    do_before_first_spawn ();
    let pk = DLS.get_initial_keys () in

    (* [term_sync] is used to synchronize with the joining domains *)
    let term_sync =
      Raw.{ state = Running ;
            mut = Mutex.create () ;
            cond = Condition.create () }
    in

    let body () =
      match
        DLS.create_dls ();
        DLS.set_initial_keys pk;
        let res = f () in
        res
      with
      (* Run the [at_exit] callbacks when the domain computation either
        terminates normally or exceptionally. *)
      | res ->
          (* If the domain computation terminated normally, but the
            [at_exit] callbacks raised an exception, then return the
            exception. *)
          do_at_exit ();
          res
      | exception exn ->
          (* If both the domain computation and the [at_exit] callbacks
            raise exceptions, then ignore the exception from the
            [at_exit] callbacks and return the original exception. *)
          (try do_at_exit () with _ -> ());
          raise exn
    in
    let domain = Raw.spawn body term_sync in
    { domain ; term_sync }

  let spawn_safe f = spawn_with_dls (fun (_ : DLS.password) -> f ())

  let spawn = spawn_safe

  let join { term_sync ; _ } =
    let open Raw in
    let rec loop () =
      match term_sync.state with
      | Running ->
          Condition.wait term_sync.cond term_sync.mut;
          loop ()
      | Finished res ->
          res
    in
    match Mutex.protect term_sync.mut loop with
    | Ok x -> x
    | Error ex -> raise ex

  let recommended_domain_count = Raw.get_recommended_domain_count
end

module type S4 = sig
  [@@@warning "-32"]

  module DLS : sig
    type password
    val initial_password : password
    val with_password : (password -> 'a) -> 'a

    type 'a key
    val new_key : ?split_from_parent:('a -> 'a) -> (unit -> 'a) -> 'a key
    val new_key_safe : ?split_from_parent:('a -> (password -> 'a)) -> (password -> 'a) -> 'a key
    val get : 'a key -> 'a
    val get' : password -> 'a key -> 'a
    val set : 'a key -> 'a -> unit
    val set' : password -> 'a key -> 'a -> unit

    val init : unit -> unit
  end

  type !'a t
  val spawn : (unit -> 'a) -> 'a t
  val spawn_safe : (unit -> 'a) -> 'a t
  val spawn_with_dls : (DLS.password -> 'a) -> 'a t
  val join : 'a t -> 'a
  type id = private int
  val get_id : 'a t -> id
  val self : unit -> id
  val cpu_relax : unit -> unit
  val is_main_domain : unit -> bool
  val recommended_domain_count : unit -> int
  val before_first_spawn : (unit -> unit) -> unit
  val at_exit : (unit -> unit) -> unit
  val at_exit_safe : (unit -> unit) -> unit
  val at_exit' : DLS.password -> (unit -> unit) -> unit
  val do_at_exit : unit -> unit
end

module type S5 = sig
  module DLS : sig
    type password
    val initial_password : password
    val with_password : (password -> 'a @ contended portable) @ portable -> 'a @ contended portable @@ portable

    type 'a key : value mod portable uncontended
    val new_key : ?split_from_parent:('a -> 'a) -> (unit -> 'a) -> 'a key
    val new_key_safe : ?split_from_parent:('a -> (password -> 'a) @ portable) @ portable -> (password -> 'a) @ portable -> 'a key @@ portable
    val get : 'a key -> 'a
    val get' : password -> 'a key -> 'a @@ portable
    val set : 'a key -> 'a -> unit
    val set' : password -> 'a key -> 'a -> unit @@ portable

    val init : unit -> unit
  end

  type !'a t
  val spawn : (unit -> 'a) -> 'a t
  val spawn_safe : (unit -> 'a) @ portable -> 'a t @@ portable
  val spawn_with_dls : (DLS.password -> 'a) @ portable -> 'a t @@ portable
  val join : 'a t -> 'a @@ portable
  type id = private int
  val get_id : 'a t -> id @@ portable
  val self : unit -> id @@ portable
  val cpu_relax : unit -> unit @@ portable
  val is_main_domain : unit -> bool @@ portable
  val recommended_domain_count : unit -> int @@ portable
  val before_first_spawn : (unit -> unit) -> unit
  val at_exit : (unit -> unit) -> unit
  val at_exit_safe : (unit -> unit) @ portable -> unit @@ portable
  val at_exit' : DLS.password -> (unit -> unit) -> unit @@ portable
  val do_at_exit : unit -> unit @@ portable
end

let runtime_4_impl = (module Runtime_4 : S4)
let runtime_5_impl = (module Runtime_5 : S5)

let impl = if runtime5 () then runtime_5_impl else (Obj.magic (runtime_4_impl : (module S4)) : (module S5))

include (val impl : S5)

let () = DLS.init ()

let _ = Stdlib.set_do_domain_local_at_exit do_at_exit
