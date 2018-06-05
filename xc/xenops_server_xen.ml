(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Xenops_interface
open Xenops_utils
open Xenops_server_plugin
open Xenops_helpers
open Xenstore
open Xenops_utils
open Xenops_task
open Cancel_utils

module D = Debug.Make(struct let name = service_name end)
open D

module RRDD = Rrd_client.Client

let simplified = false

(* libxl_internal.h:DISABLE_UDEV_PATH *)
let disable_udev_path = "libxl/disable_udev"

let store_domid = 0
let console_domid = 0

let _device_model = "device-model"
let _xenguest = "xenguest"
let _emu_manager = "emu-manager"

let run cmd args =
  debug "%s %s" cmd (String.concat " " args);
  fst(Forkhelpers.execute_command_get_output cmd args)

let choose_alternative kind default platformdata =
  debug "looking for %s in [ %s ]" kind (String.concat "; " (List.map (fun (k, v) -> k ^ " : " ^v) platformdata));
  if List.mem_assoc kind platformdata then begin
    let x = List.assoc kind platformdata in
    let dir = Filename.concat !Xc_resources.alternatives kind in
    let available = try Array.to_list (Sys.readdir dir) with _ -> [] in
    (* If x has been put in the directory (by root) then it's safe to use *)
    if List.mem x available
    then Filename.concat dir x
    else begin
      error "Invalid platform:%s=%s (check execute permissions of %s)" kind x (Filename.concat dir x);
      default
    end
  end else default

(* We allow qemu-dm to be overriden via a platform flag *)
let choose_qemu_dm x = Device.(
    if List.mem_assoc _device_model x
    then Profile.of_string (List.assoc _device_model x)
    else Profile.fallback
  )

(* We allow xenguest to be overriden via a platform flag *)
let choose_xenguest x = choose_alternative _xenguest !Xc_resources.xenguest x

(* We allow emu-manager to be overriden via a platform flag *)
let choose_emu_manager x = choose_alternative _emu_manager !Xc_resources.emu_manager x

type xendisk = Storage_interface.xendisk = {
  params: string; (** Put into the "params" key in xenstore *)

  extra: (string * string) list;
  (** Key-value pairs to be put into the "extra" subdirectory underneath the
      xenstore backend *)

  backend_type: string;
} [@@deriving rpcty]


type block_device = Storage_interface.block_device = {
  path: string; (** Path to the block device *)
} [@@deriving rpcty]


type file = Storage_interface.file = {
  path: string; (** Path to the raw file *)
} [@@deriving rpcty]


type nbd = Storage_interface.nbd = {
  uri: string;
} [@@deriving rpcty]

type implementation = Storage_interface.implementation =
  | XenDisk of xendisk
  | BlockDevice of block_device
  | File of file
  | Nbd of nbd
[@@deriving rpcty]

type qemu_frontend =
  | Empty
  | Name of string (* block device path or bridge name *)
  | Nbd of nbd
  | Device of Device_common.device
  [@@deriving rpcty]

type storage_backend = Storage_interface.backend = {
  implementations: implementation list;
} [@@deriving rpcty]

type attached_vdi = {
  domid: int;
  attach_info: storage_backend;
} [@@deriving rpcty]

module VmExtra = struct

  let domain_config_of_vm vm =
    let open Vm in
    let open Domain in
    match vm.ty with
    | PV _      -> X86 { emulation_flags = [] }
    | PVinPVH _ -> X86 { emulation_flags = emulation_flags_pvh }
    | HVM _     -> X86 { emulation_flags = emulation_flags_all }

  (* Known versions of the VM persistent metadata created by xenopsd *)
  let persistent_version_pre_lima = 0
  let persistent_version_lima     = 1

  (** Extra data we store per VM. The persistent data is preserved when
      the domain is suspended so it can be re-used in the following 'create'
      which is part of 'resume'. *)
  type persistent_t = {
    (* This field indicates the version of the persistent record with which
       the VM started, and it stays constant through xenopsd VM migration,
       resume etc operations until the VM shuts down. *)
    version: int [@default persistent_version_pre_lima];
    build_info: Domain.build_info option;
    ty: Vm.builder_info option;
    last_start_time: float [@default 0.0];
    domain_config: Domain.arch_domainconfig option;
    nomigrate: bool [@default false];  (* platform:nomigrate   at boot time *)
    nested_virt: bool [@default false];(* platform:nested_virt at boot time *)
    profile: Device.Profile.t option;
    suspend_memory_bytes: int64 [@default 0L];
    qemu_vbds: (Vbd.id * (int * qemu_frontend)) list [@default []];
    qemu_vifs: (Vif.id * (int * qemu_frontend)) list [@default []];
    pci_msitranslate: bool [@default false];
    pci_power_mgmt: bool [@default false];
    pv_drivers_detected: bool [@default false];
  } [@@deriving rpcty]

  let default_persistent_t = match Rpcmarshal.unmarshal typ_of_persistent_t (Rpc.Dict []) with Ok x -> x | _ -> failwith "Failed to make default_persistent_t"

  type t = {
    persistent: persistent_t
  } [@@deriving rpcty]
end

module DB = struct
  include TypedTable(struct
      include VmExtra
      let namespace = "extra"
      type key = string
      let key vm = [ vm ]
    end)

  (* This function will leave untouched the profile of any VM started with the xenopsd persistent
     record version 1 (or later), and it will revise the profile of any qemu-trad VM started with
     a persistent record without a version field (which defaults to version 0) *)
  let revise_profile_qemu_trad vm persistent =
      Device.Profile.{persistent with VmExtra.profile =
        match persistent.VmExtra.profile with
        | Some Qemu_trad when persistent.VmExtra.version = VmExtra.persistent_version_pre_lima ->
          debug "vm %s: revised %s->%s" vm Name.qemu_trad Name.qemu_upstream_compat;
          Some Qemu_upstream_compat
        | x -> x
      }

  let revision_of vm persistent =
    persistent
    |> revise_profile_qemu_trad vm

end

(* These updates are local plugin updates, distinct from those that are
   exposed via the UPDATES API *)
let internal_updates = Updates.empty scheduler

let safe_rm xs path =
  debug "xenstore-rm %s" path;
  try
    xs.Xs.rm path
  with _ -> ()

let this_domid ~xs =
  (* If we're in dom0 then no-one will have created the "domid" key. *)
  try
    int_of_string (xs.Xs.read "domid")
  with _ -> 0

let uuid_of_string x = match Uuidm.of_string x with
  | Some x -> x
  | None ->
    let msg = Printf.sprintf "string '%s' is not a valid UUID" x in
    error "%s" msg;
    failwith msg

let uuid_of_vm vm = uuid_of_string vm.Vm.id

let uuid_of_di di = Ez_xenctrl_uuid.uuid_of_handle di.Xenctrl.handle

let di_of_uuid ~xc ~xs uuid =
  let open Xenctrl in
  let uuid' = Uuidm.to_string uuid in
  let all = domain_getinfolist xc 0 in
  let possible = List.filter (fun x -> uuid_of_di x = uuid) all in
  match possible with
  | [] -> None
  | [x] -> Some x
  | xs ->
    let domid_list = String.concat ", " (List.map (fun x -> string_of_int x.domid) xs) in
    error "VM %s: there are %d domains (%s) with the same uuid: one or more have leaked" uuid' (List.length possible) domid_list;
    raise (Xenopsd_error (Internal_error (Printf.sprintf "More than one domain with uuid (%s): %s" uuid' domid_list)))

let domid_of_uuid ~xc ~xs uuid =
  (* We don't fully control the domain lifecycle because libxenguest will actually
     destroy a domain on suspend. Therefore we only rely on state in xenstore *)
  let dir = Printf.sprintf "/vm/%s/domains" (Uuidm.to_string uuid) in
  try
    match xs.Xs.directory dir |> List.map int_of_string |> List.sort compare with
    | [] -> None
    | [x] -> Some x
    | xs ->
      let domid_list = String.concat ", " (List.map string_of_int xs) in
      error "More than 1 domain associated with a VM. This is no longer OK!";
      raise (Xenopsd_error (Internal_error (Printf.sprintf "More than one domain with uuid (%s): %s" (Uuidm.to_string uuid) domid_list)))
  with e ->
    error "Failed to read %s: has this domain already been cleaned up?" dir;
    None

let get_uuid ~xc domid = uuid_of_di (Xenctrl.domain_getinfo xc domid)

let device_kind_of_backend_keys backend_keys =
  try Device_common.vbd_kind_of_string (List.assoc "backend-kind" backend_keys)
  with Not_found -> Device_common.Vbd !Xenopsd.default_vbd_backend_kind

let params_of_backend backend =
  let xendisks, blockdevs, files, nbds = Storage_interface.implementations_of_backend backend in
  let xenstore_data = match xendisks with
    | xendisk::_ ->
      let backend_kind = xendisk.Storage_interface.backend_type in
      let xenstore_data = xendisk.Storage_interface.extra in
      if List.mem_assoc backend_kind xenstore_data then xenstore_data else ("backend-kind", backend_kind) :: xenstore_data
    | [] ->
      raise (Xenopsd_error (Internal_error ("Could not find XenDisk implementation: " ^ (Storage_interface.(rpc_of backend) backend |> Jsonrpc.to_string))))
  in
  let params, extra_keys = match blockdevs, files, nbds, xendisks with
  | {path}::_, _, _, _ | _, {path}::_, _, _ -> (path, [])
  | _, _, {uri}::_, xendisk::_ -> (uri, ["qemu-params", xendisk.Storage_interface.params])
  | _ ->
    raise (Xenopsd_error (Internal_error ("Could not find BlockDevice, File, or Nbd implementation: " ^ (Storage_interface.(rpc_of backend) backend |> Jsonrpc.to_string))))
  in
  (params, xenstore_data, extra_keys)

let create_vbd_frontend ~xc ~xs task frontend_domid vdi =
  let frontend_vm_id = get_uuid ~xc frontend_domid |> Uuidm.to_string in
  let backend_vm_id = get_uuid ~xc vdi.domid |> Uuidm.to_string in
  match domid_of_uuid ~xc ~xs (uuid_of_string backend_vm_id) with
  | None ->
    error "VM = %s; domid = %d; Failed to determine domid of backend VM id: %s" frontend_vm_id frontend_domid backend_vm_id;
    raise (Xenopsd_error (Does_not_exist("domain", backend_vm_id)))
  | Some backend_domid when backend_domid = frontend_domid -> begin
      (* There's no need to use a PV disk if we're in the same domain *)
      let _xendisks, blockdevs, files, nbds = Storage_interface.implementations_of_backend vdi.attach_info in
      match files, blockdevs, nbds with
      | {path}::_, _, _ | _, {path}::_, _ -> Name path
      | _, _, nbd::_ -> Nbd nbd
      | [], [], [] -> raise (Xenopsd_error (Internal_error ("Could not find File, BlockDevice, or Nbd implementation: " ^ (Storage_interface.(rpc_of backend) vdi.attach_info |> Jsonrpc.to_string))))
    end
  | Some backend_domid ->
    let params, xenstore_data, extra_keys = params_of_backend vdi.attach_info in
    let kind = device_kind_of_backend_keys xenstore_data in
    let t = {
      Device.Vbd.mode = Device.Vbd.ReadWrite;
      device_number = None; (* we don't mind *)
      phystype = Device.Vbd.Phys;
      params;
      dev_type = Device.Vbd.Disk;
      unpluggable = true;
      protocol = None;
      kind;
      extra_backend_keys = (List.map (fun (k, v) -> "sm-data/" ^ k, v) xenstore_data) @ extra_keys;
      extra_private_keys = [];
      backend_domid = backend_domid;
    } in
    let device = Xenops_task.with_subtask task "Vbd.add"
        (fun () -> Device.Vbd.add task ~xc ~xs ~hvm:false t frontend_domid) in
    Device device

let destroy_vbd_frontend ~xc ~xs task disk =
  match disk with
  | Empty | Name _ | Nbd _ -> ()
  | Device device ->
    Xenops_task.with_subtask task "Vbd.clean_shutdown"
      (fun () ->
         (* Outstanding requests may cause a transient 'refusing to close'
            but this can be safely ignored because we're controlling the
            frontend and all users of it. *)
         Device.Vbd.clean_shutdown_async ~xs device;
         Device.Vbd.clean_shutdown_wait task ~xs ~ignore_transients:true device
      )


module Storage = struct
  open Storage
  open Storage_interface
  module Client = Storage_client.Client

  let id_of = id_of
  let epoch_begin = epoch_begin
  let epoch_end = epoch_end

  (* We need to deal with driver domains here: *)
  let attach_and_activate ~xc ~xs task vm dp sr vdi read_write =
    let result = attach_and_activate task vm dp sr vdi read_write in
    let backend = Xenops_task.with_subtask task (Printf.sprintf "Policy.get_backend_vm %s %s %s" vm (Sr.string_of sr) (Vdi.string_of vdi))
        (transform_exception (fun () -> Client.Policy.get_backend_vm "attach_and_activate" vm sr vdi)) in
    match domid_of_uuid ~xc ~xs (uuid_of_string backend) with
    | None ->
      failwith (Printf.sprintf "Driver domain disapppeared: %s" backend)
    | Some domid ->
      { domid = domid; attach_info = result }

  let deactivate = deactivate
  let dp_destroy = dp_destroy
  let get_disk_by_name = get_disk_by_name
end

let print_fork_error f =
  try
    f ()
  with Forkhelpers.Spawn_internal_error(stderr, stdout, status) as e ->
    begin match status with
      | Unix.WEXITED n ->
        error "Forkhelpers.Spawn_internal_error(%s, %s, WEXITED %d)" stderr stdout n;
        raise e
      | Unix.WSIGNALED n ->
        error "Forkhelpers.Spawn_internal_error(%s, %s, WSIGNALED %d)" stderr stdout n;
        raise e
      | Unix.WSTOPPED n ->
        error "Forkhelpers.Spawn_internal_error(%s, %s, WSTOPPED %d)" stderr stdout n;
        raise e
    end

let run_command cmd args =
  debug "running %s %s" cmd (String.concat " " args);
  let stdout, stderr = print_fork_error (fun () -> Forkhelpers.execute_command_get_output cmd args) in
  stdout

module NbdClient = struct
  let start_nbd_client ~unix_socket_path ~export_name =
    run_command "/opt/xensource/libexec/nbd_client_manager.py" ["connect"; "--path"; unix_socket_path; "--exportname"; export_name]
    |> String.trim

  let stop_nbd_client ~nbd_device =
    run_command "/opt/xensource/libexec/nbd_client_manager.py" ["disconnect"; "--device"; nbd_device]
    |> ignore

  let with_nbd_device ~unix_socket_path ~export_name f =
    let nbd_device = start_nbd_client ~unix_socket_path ~export_name in
    finally
      (fun () -> f nbd_device)
      (fun () ->
         try
           stop_nbd_client ~nbd_device
         with e ->
           warn "ignoring exception while disconnecting nbd-client from %s: %s" nbd_device (Printexc.to_string e)
      )

  let with_nbd_device ~nbd =
    let unix_socket_path, export_name = Storage_interface.parse_nbd_uri nbd in
    with_nbd_device ~unix_socket_path ~export_name
end

let with_disk ~xc ~xs task disk write f = match disk with
  | Local path -> f path
  | VDI path ->
    let open Storage in
    let sr, vdi = get_disk_by_name task path in
    let dp = Client.DP.create "with_disk" (Printf.sprintf "xenopsd/task/%s" (Xenops_task.id_of_handle task)) in
    finally
      (fun () ->
         let frontend_domid = this_domid ~xs in
         let frontend_vm = get_uuid ~xc frontend_domid |> Uuidm.to_string in
         let vdi = attach_and_activate ~xc ~xs task frontend_vm dp sr vdi write in
         let device = create_vbd_frontend ~xc ~xs task frontend_domid vdi in
         finally
           (fun () ->
              match device with
              | Empty     -> f ""
              | Name path -> f path
              | Device device -> f (Device_common.block_device_of_device device)
              | Nbd nbd ->
                debug "with_disk: using nbd-client for %s" (Storage_interface.(rpc_of nbd) nbd |> Jsonrpc.to_string);
                NbdClient.with_nbd_device ~nbd f
           )
           (fun () ->
              destroy_vbd_frontend ~xc ~xs task device
           )
      )
      (fun () -> dp_destroy task dp)

module Mem = struct
  let wrap f =
    try Some (f ())
    with
    | Memory_interface.MemoryError (Memory_interface.Cannot_free_this_much_memory(needed, free)) ->
      let needed = Memory.bytes_of_kib needed in
      let free = Memory.bytes_of_kib free in
      error "Cannot free %Ld; only %Ld are available" needed free;
      raise (Xenopsd_error (Cannot_free_this_much_memory(needed, free)))
    | Memory_interface.MemoryError (Memory_interface.Domains_refused_to_cooperate domids) ->
      debug "Got error_domains_refused_to_cooperate_code from ballooning daemon";
      Xenctrl.with_intf
        (fun xc ->
           let vms = List.map (get_uuid ~xc) domids |> List.map Uuidm.to_string in
           raise (Xenopsd_error (Vms_failed_to_cooperate(vms)))
        )
    | Unix.Unix_error(Unix.ECONNREFUSED, "connect", _) ->
      info "ECONNREFUSED talking to squeezed: assuming it has been switched off";
      None
    | Unix.Unix_error(Unix.ENOENT, "connect", _) ->
      info "ENOENT talking to squeezed: assuming it has never been started";
      None
  open Memory_client
  let do_login dbg = wrap (fun () -> Client.login dbg "xenopsd")

  (* Each "login" causes all unused reservations to be freed, therefore we log in once *)
  let cached_session_id = ref None
  let cached_session_id_m = Mutex.create ()
  let get_session_id =
    fun dbg ->
      Mutex.execute cached_session_id_m
        (fun () ->
           match !cached_session_id with
           | Some x -> x
           | None ->
             let s = do_login dbg in
             cached_session_id := Some s;
             s
        )

  (** If we fail to allocate because VMs either failed to co-operate or because they are still booting
      and haven't written their feature-balloon flag then retry for a while before finally giving up.
      In particular this should help smooth over the period when VMs are booting and haven't loaded their balloon
      drivers yet. *)
  let retry f =
    let start = Unix.gettimeofday () in
    let interval = 10. in
    let timeout = 60. in
    let rec loop () =
      try
        f ()
      with
      | Memory_interface.MemoryError Memory_interface.Domains_refused_to_cooperate _
      | Memory_interface.MemoryError (Memory_interface.Cannot_free_this_much_memory(_, _)) as e ->
        let now = Unix.gettimeofday () in
        if now -. start > timeout then raise e else begin
          debug "Sleeping %.0f before retrying" interval;
          Thread.delay interval;
          loop ()
        end in
    loop ()

  (** Reserve a particular amount of memory and return a reservation id *)
  let reserve_memory_range_exn dbg min max =
    Opt.map
      (fun session_id ->
         let reservation_id, reserved_memory  =
           retry
             (fun () ->
                debug "Requesting a host memory reservation between %Ld and %Ld" min max;
                let reservation_id, kib = Client.reserve_memory_range dbg session_id min max in
                debug "Memory reservation size = %Ld (reservation_id = %s)" kib reservation_id;
                reservation_id, kib
             )
         in
         (* Post condition: *)
         assert (reserved_memory >= min);
         assert (reserved_memory <= max);
         reserved_memory, (reservation_id, reserved_memory)
      ) (get_session_id dbg)

  let reserve_memory_range dbg min max : (int64 * (string * int64)) option =
    wrap (fun () -> reserve_memory_range_exn dbg min max) |> Opt.join

  (** Delete a reservation given by [reservation_id] *)
  let delete_reservation_exn dbg (reservation_id, _) =
    Opt.map
      (fun session_id ->
         debug "delete_reservation %s" reservation_id;
         Client.delete_reservation dbg session_id reservation_id
      ) (get_session_id dbg)
  let delete_reservation dbg r =
    let (_: unit option option) = wrap (fun () -> delete_reservation_exn dbg r) in
    ()

  (** Reserves memory, passes the id to [f] and cleans up afterwards. If the user
      wants to keep the memory, then call [transfer_reservation_to_domain]. *)
  let with_reservation dbg min max f =
    let amount, id = Opt.default (min, ("none", min)) (reserve_memory_range dbg min max) in
    try
      f amount id
    with e ->
      delete_reservation dbg id;
      raise e


  (** Transfer this 'reservation' to the given domain id *)
  let transfer_reservation_to_domain_exn dbg domid (reservation_id, amount) =
    match get_session_id dbg with
    | Some session_id ->
      begin
        try
          Client.transfer_reservation_to_domain dbg session_id reservation_id domid
        with Unix.Unix_error(Unix.ECONNREFUSED, "connect", _) ->
          (* This happens when someone manually runs 'service squeezed stop' *)
          Mutex.execute cached_session_id_m (fun () -> cached_session_id := None);
          error "Ballooning daemon has disappeared. Manually setting domain maxmem for domid = %d to %Ld KiB" domid amount;
          Xenctrl.with_intf (fun xc -> Xenctrl.domain_setmaxmem xc domid amount);
      end
    | None ->
      info "No ballooning daemon. Manually setting domain maxmem for domid = %d to %Ld KiB" domid amount;
      Xenctrl.with_intf (fun xc -> Xenctrl.domain_setmaxmem xc domid amount)

  let transfer_reservation_to_domain dbg domid r =
    let (_: unit option) = wrap (fun () -> transfer_reservation_to_domain_exn dbg domid r) in
    ()

  let query_reservation_of_domain dbg domid =
    match get_session_id dbg with
    | Some session_id ->
      begin
        try
          let reservation_id = Client.query_reservation_of_domain dbg session_id domid in
          debug "Memory reservation_id = %s" reservation_id;
          reservation_id
        with
        | Unix.Unix_error(Unix.ECONNREFUSED, "connect", _) ->
          error "Ballooning daemon has disappeared. Cannot query reservation_id for domid = %d" domid;
          raise Memory_interface.(MemoryError No_reservation)
        | _ ->
          error "Internal error. Cannot query reservation_id for domid = %d" domid;
          raise Memory_interface.(MemoryError No_reservation)
      end
    | None ->
      info "No ballooning daemon. Cannot query reservation_id for domid = %d" domid;
      raise Memory_interface.(MemoryError No_reservation)

  (** After an event which frees memory (eg a domain destruction), perform a one-off memory rebalance *)
  let balance_memory dbg =
    debug "rebalance_memory";
    Client.balance_memory dbg

end

(* We store away the device name so we can lookup devices by name later *)
let _device_id kind = Device_common.string_of_kind kind ^ "-id"

(* Return the xenstore device with [kind] corresponding to [id]

   This is an inefficient operation because xenstore indexes the devices by devid, not id,
   so in order to find an id we need to go through potentially all the devids in the tree.

   Therefore, we need to cache the results to decrease the overall xenstore read accesses.
   During VM lifecycle operations, this cache will reduce xenstored read accesses from
   O(n^2) to O(n), where n is the number of VBDs in a VM.
*)

module DeviceCache = struct
  module PerVMCache = struct
    include Hashtbl
    let create n = (create n, Mutex.create ())
  end
  include Hashtbl
  let create n = (create n, Mutex.create())
  let discard (cache, mutex) domid = Mutex.execute mutex (fun () ->
      debug "removing device cache for domid %d" domid;
      remove cache domid
    )
  exception NotFoundIn of string option list
  let get (cache, mutex) fetch_all_f fetch_one_f domid key =
    let (domid_cache, domid_mutex) = Mutex.execute mutex (fun () ->
        if mem cache domid then
          find cache domid
        else
          let domid_cache = PerVMCache.create 16 in
          debug "adding device cache for domid %d" domid;
          replace cache domid domid_cache;
          domid_cache
      ) in
    Mutex.execute domid_mutex (fun () ->
        let refresh_cache () = (* expensive *)
          PerVMCache.reset domid_cache;
          List.iter (fun (k,v) -> PerVMCache.replace domid_cache k v) (fetch_all_f ())
        in
        (try
           let cached_value = PerVMCache.find domid_cache (Some key) in
           (* cross-check cached value with original value to verify it is up-to-date *)
           let fetched_value = fetch_one_f cached_value in
           if cached_value <> fetched_value then
             ( (* force refresh of domid cache *)
               refresh_cache ()
             )
         with _ -> (* attempt to refresh cache *)
           (try refresh_cache () with _ -> ())
        );
        try
          PerVMCache.find domid_cache (Some key)
        with _ ->
          let keys = try PerVMCache.fold (fun k v acc -> k::acc) domid_cache [] with _ -> [] in
          raise (NotFoundIn keys)
      )
end

let device_cache = DeviceCache.create 256

let device_by_id xc xs vm kind id =
  match vm |> uuid_of_string |> domid_of_uuid ~xc ~xs with
  | None ->
    debug "VM = %s; does not exist in domain list" vm;
    raise (Xenopsd_error (Does_not_exist("domain", vm)))
  | Some frontend_domid ->
    let fetch_all_from_xenstore_f () = (* expensive *)
      let devices = Device_common.list_frontends ~xs frontend_domid in
      let key = _device_id kind in
      let id_of_device device =
        let path = Device_common.get_private_data_path_of_device device in
        try Some (xs.Xs.read (Printf.sprintf "%s/%s" path key))
        with _ -> None in
      let ids = List.map id_of_device devices in
      List.combine ids devices
    in
    let fetch_one_from_xenstore_f cached_device =
      let cached_frontend_devid = cached_device.Device_common.frontend.Device_common.devid in
      let xenstored_device = Device_common.list_frontends ~xs ~for_devids:[cached_frontend_devid] frontend_domid in
      match xenstored_device with [] -> raise Not_found | x ::_ -> x
    in
    try DeviceCache.get device_cache fetch_all_from_xenstore_f fetch_one_from_xenstore_f frontend_domid id
    with DeviceCache.NotFoundIn ids ->
      debug "VM = %s; domid = %d; Device is not active: kind = %s; id = %s; active devices = [ %s ]" vm frontend_domid (Device_common.string_of_kind kind) id (String.concat ", " (List.map (Opt.default "None") ids));
      raise (Xenopsd_error Device_not_connected)

(* Extra keys to store in VBD backends to allow us to deactivate VDIs: *)
type backend = disk option [@@deriving rpcty]
let _vdi_id = "vdi-id"
let _dp_id = "dp-id"

let set_stubdom ~xs domid domid' =
  xs.Xs.write (Printf.sprintf "/local/domain/%d/stub-domid" domid) (string_of_int domid')

let get_stubdom ~xs domid =
  try Some (int_of_string (xs.Xs.read (Printf.sprintf "/local/domain/%d/stub-domid" domid))) with _ -> None

module HOST = struct
  include Xenops_server_skeleton.HOST

  let stat () =
    (* The boot-time CPU info is copied into a file in @ETCDIR@/ in the xenservices init script;
       we use that to generate CPU records from. This ensures that if xapi is started after someone has
       modified dom0's VCPUs we don't change out host config... [Important to get this right, otherwise
       pool homogeneity checks fail] *)
    let get_cpuinfo () =
      let cpu_info_file =
        try Unix.access !Resources.cpu_info_file [ Unix.F_OK ]; !Resources.cpu_info_file
        with _ -> "/proc/cpuinfo" in
      let in_chan = open_in cpu_info_file in
      let tbl = Hashtbl.create 32 in
      let rec get_lines () =
        let s = input_line in_chan in
        begin
          try
            let i = String.index s ':' in
            let k = String.trim (String.sub s 0 i) in
            let v =
              if String.length s < i + 2
              then ""
              else String.sub s (i + 2) (String.length s - i - 2)
            in
            Hashtbl.add tbl k v
          with e ->
            info "cpuinfo: skipping line [%s]" s
        end;
        if s <> "" then get_lines ()
      in
      get_lines ();
      close_in in_chan;
      let find key =
        if Hashtbl.mem tbl key
        then Hashtbl.find tbl key
        else "unknown" in
      find "vendor_id",
      find "model name",
      find "cpu MHz",
      find "flags",
      find "stepping",
      find "model",
      find "cpu family"
    in
    let vendor, modelname, speed, flags, stepping, model, family = get_cpuinfo () in

    with_xc_and_xs
      (fun xc xs ->
         let open Xenctrl in
         let p = physinfo xc in
         let cpu_count = p.nr_cpus in
         let socket_count = p.nr_cpus / (p.threads_per_core * p.cores_per_socket) in

         let features = get_featureset xc Featureset_host in
         let features_pv = get_featureset xc Featureset_pv in
         let features_hvm = get_featureset xc Featureset_hvm in
         let features_oldstyle = oldstyle_featuremask xc in

         (* Compatibility with Xen 4.7 *)
         (* This is temporary until new CPUID/MSR levelling work is done *)
         let cpuid_common_1d_features = 0x0183f3ffL in

         (* Set X86_FEATURE_HTT in 1d *)
         features_pv.(0)  <- Int64.logor features_pv.(0)  0x10000000L;
         features_hvm.(0) <- Int64.logor features_hvm.(0) 0x10000000L;

         (* Set X86_FEATURE_X2APIC in 1c *)
         features_pv.(1)  <- Int64.logor features_pv.(1)  0x200000L;
         features_hvm.(1) <- Int64.logor features_hvm.(1) 0x200000L;

         (* Share CPUID_COMMON_1D_FEATURES with e1d *)
         let tmp = Int64.logand features_pv.(0)  cpuid_common_1d_features in
         features_pv.(2)  <- Int64.logor features_pv.(2)  tmp;
         let tmp = Int64.logand features_hvm.(0) cpuid_common_1d_features in
         features_hvm.(2) <- Int64.logor features_hvm.(2) tmp;

         (* Set X86_FEATURE_CMP_LEGACY in e1c *)
         features_pv.(3)  <- Int64.logor features_pv.(3)  0x2L;
         features_hvm.(3) <- Int64.logor features_hvm.(3) 0x2L;

         let v = version xc in
         let xen_version_string = Printf.sprintf "%d.%d%s" v.major v.minor v.extra in
         let xen_capabilities = version_capabilities xc in

         {
           Host.cpu_info = {
             Host.cpu_count;
             socket_count;
             vendor;
             speed;
             modelname;
             family;
             model;
             stepping;
             flags;
             features;
             features_pv;
             features_hvm;
             features_oldstyle;
           };
           hypervisor = {
             Host.version = xen_version_string;
             capabilities = xen_capabilities;
           }
         }
      )

  let get_console_data () =
    with_xc_and_xs
      (fun xc xs ->
         let raw = Bytes.of_string (Xenctrl.readconsolering xc) in
         (* There may be invalid XML characters in the buffer, so remove them *)
         let is_printable chr =
           let x = int_of_char chr in
           x=13 || x=10 || (x >= 0x20 && x <= 0x7e) in
         for i = 0 to Bytes.length raw - 1 do
           if not(is_printable (Bytes.get raw i))
           then Bytes.set raw i ' '
         done;
         Bytes.unsafe_to_string raw
      )
  let get_total_memory_mib () =
    with_xc_and_xs
      (fun xc xs ->
         let pages_per_mib = 256L in
         Int64.(div ((Xenctrl.physinfo xc).Xenctrl.total_pages |> of_nativeint) pages_per_mib)
      )
  let send_debug_keys keys =
    with_xc_and_xs
      (fun xc xs ->
         Xenctrl.send_debug_keys xc keys
      )

  let update_guest_agent_features features =
    let root = "/guest_agent_features" in
    let perms =
      Xs_protocol.ACL.({
          owner = 0;
          other = READ;
          acl = [];
        }) in
    with_xs
      (fun xs ->
         Xs.transaction xs (fun t ->
             t.Xst.rm root;
             let write_with_perms key value =
               t.Xst.write key value;
               t.Xst.setperms key perms
             in
             write_with_perms root "";
             List.iter (fun feature ->
                 let feature_root = Filename.concat root feature.Host.name in
                 let parameters_root = Filename.concat feature_root "parameters" in
                 write_with_perms feature_root "";
                 write_with_perms parameters_root "";
                 write_with_perms
                   (Filename.concat feature_root "licensed")
                   (if feature.Host.licensed then "1" else "0");
                 List.iter
                   (fun (key, value) ->
                      write_with_perms
                        (Filename.concat parameters_root key)
                        value)
                   feature.Host.parameters)
               features))

  let upgrade_cpu_features features is_hvm =
    with_xc_and_xs
      (fun xc _ -> Xenctrl.upgrade_oldstyle_featuremask xc features is_hvm)
end

let dB_m = Mutex.create ()
let dm_of ~vm = Mutex.execute dB_m (fun () ->
    try
      let vmextra = DB.read_exn vm in
      match VmExtra.(vmextra.persistent.profile) with
      | None -> Device.Profile.fallback
      | Some x -> x
    with _ -> Device.Profile.fallback
  )

module VM = struct
  open Vm

  let will_be_hvm vm = match vm.ty with HVM _ -> true | _ -> false

  let profile_of ~vm = if will_be_hvm vm
    then Some (choose_qemu_dm vm.Xenops_interface.Vm.platformdata)
    else None

  let dm_of ~vm = dm_of vm.Vm.id

  let compute_overhead persistent vcpu_max memory_static_max shadow_multiplier =
    let open VmExtra in
    let static_max_mib = Memory.mib_of_bytes_used memory_static_max in
    let model =
      match persistent.ty with
      | Some (PV _)      -> Memory.Linux.overhead_mib
      | Some (PVinPVH _) -> Memory.PVinPVH.overhead_mib
      | Some (HVM _)     -> Memory.HVM.overhead_mib
      | None             -> failwith "cannot compute memory overhead: unable to determine domain type"
    in
    model static_max_mib vcpu_max shadow_multiplier |> Memory.bytes_of_mib

  let shutdown_reason = function
    | Reboot -> Domain.Reboot
    | PowerOff -> Domain.PowerOff
    | Suspend -> Domain.Suspend
    | Halt -> Domain.Halt
    | S3Suspend -> Domain.S3Suspend

  (* We compute our initial target at memory reservation time, done before the domain
     is created. We consume this information later when the domain is built. *)
  let set_initial_target ~xs domid initial_target =
    xs.Xs.write (Printf.sprintf "/local/domain/%d/memory/initial-target" domid)
      (Int64.to_string initial_target)
  let get_initial_target ~xs domid =
    Int64.of_string (xs.Xs.read (Printf.sprintf "/local/domain/%d/memory/initial-target" domid))

  let domain_type_path domid = Printf.sprintf "/local/domain/%d/domain-type" domid

  let set_domain_type ~xs domid vm =
    let domain_type =
      match vm.ty with
      | HVM _     -> "hvm"
      | PV _      -> "pv"
      | PVinPVH _ -> "pv-in-pvh"
    in
    xs.Xs.write (domain_type_path domid) domain_type

  let get_domain_type ~xs di =
    try
      match xs.Xs.read (domain_type_path di.Xenctrl.domid) with
      | "hvm"       -> Domain_HVM
      | "pv"        -> Domain_PV
      | "pv-in-pvh" -> Domain_PVinPVH
      | x           ->
        warn "domid = %d; Undefined domain type found (%s)" di.Xenctrl.domid x;
        Domain_undefined
    with Xs_protocol.Enoent _ ->
      (* Fallback for the upgrade case, where the new xs key may not exist *)
      if di.Xenctrl.hvm_guest then
        Domain_HVM
      else
        Domain_PV

  (* Called from a xenops client if it needs to resume a VM that was suspended on a pre-xenopsd host. *)
  let generate_state_string vm =
    let open Memory in
    let builder_spec_info =
      match vm.ty with
      | HVM hvm_info ->
        Domain.BuildHVM {
          Domain.shadow_multiplier = hvm_info.shadow_multiplier;
          video_mib = hvm_info.video_mib;
        }
      | PV { boot = Direct direct } ->
        Domain.BuildPV {
          Domain.cmdline = direct.cmdline;
          ramdisk = direct.ramdisk;
        }
      | PV { boot = Indirect { devices = [] } } ->
        raise (Xenopsd_error No_bootable_device)
      | PV { boot = Indirect ( { devices = d :: _ } ) } ->
        Domain.BuildPV {
          Domain.cmdline = "";
          ramdisk = None;
        }
      | PVinPVH _ ->
        failwith "This domain type did not exist pre-xenopsd"
    in
    let build_info = {
      Domain.memory_max = vm.memory_static_max /// 1024L;
      memory_target = vm.memory_dynamic_min /// 1024L;
      kernel = "";
      vcpus = vm.vcpu_max;
      priv = builder_spec_info;
    } in
    VmExtra.{ default_persistent_t with
              build_info = Some build_info;
              ty = Some vm.ty;
              (* Earlier than the PV drivers update time, therefore
                 any cached PV driver information will be kept. *)
              last_start_time = 0.0;
              profile = profile_of ~vm;
    } |> rpc_of VmExtra.persistent_t |> Jsonrpc.to_string

  let mkints n =
    let rec loop a b = if a = b then [] else a :: (loop (a + 1) b) in
    loop 0 n

  (* Could use fold_left to get the same value, but that would necessarily go through the whole list everytime, instead of the first n items, only. *)
  (* ToDo: This is complicated enough to warrant a test. *)
  (* Is it wise to fail silently on negative values?  (They are treated as zero, here.)
     Pro: Would mask fewer bugs.
     Con: Less robust.
     *)
  let take n list =
    let ($) f a = f a in
    let rec helper i acc list =
      if i <= 0 || list = []
      then acc
      else helper (i-1)  (List.hd list :: acc) (List.tl list)
    in List.rev $ helper n [] list

  let generate_create_info ~xc ~xs vm persistent =
    let ty = match persistent.VmExtra.ty with | Some ty -> ty | None -> vm.ty in
    let hvm = match ty with | HVM _ | PVinPVH _ -> true | PV _ -> false in
    (* XXX add per-vcpu information to the platform data *)
    (* VCPU configuration *)
    let pcpus = Xenctrlext.get_max_nr_cpus xc in
    let all_pcpus = mkints pcpus in
    let all_vcpus = mkints vm.vcpu_max in
    let masks = match vm.scheduler_params.affinity with
      | [] ->
        (* Every vcpu can run on every pcpu *)
        List.map (fun _ -> all_pcpus) all_vcpus
      | m :: ms ->
        (* Treat the first as the template for the rest *)
        let defaults = List.map (fun _ -> m) all_vcpus in
        take vm.vcpu_max (m :: ms @ defaults) in
    (* convert a mask into a binary string, one char per pCPU *)
    let bitmap cpus: string =
      let cpus = List.filter (fun x -> x >= 0 && x < pcpus) cpus in
      let result = Bytes.make pcpus '0' in
      List.iter (fun cpu -> Bytes.set result cpu '1') cpus;
      Bytes.unsafe_to_string result in
    let affinity =
      snd(List.fold_left (fun (idx, acc) mask ->
          idx + 1, ((Printf.sprintf "vcpu/%d/affinity" idx, bitmap mask) :: acc)
        ) (0, []) masks) in
    let weight = Opt.default [] (Opt.map
                                   (fun (w, c) -> [
                                        "vcpu/weight", string_of_int w;
                                        "vcpu/cap", string_of_int c
                                      ])
                                   vm.scheduler_params.priority
                                ) in
    let vcpus = [
      "vcpu/number", string_of_int vm.vcpu_max;
      "vcpu/current", string_of_int (match vm.ty with PVinPVH _ -> vm.vcpu_max | _ -> vm.vcpus);
    ] @ affinity @ weight in

    let default k v p = if List.mem_assoc k p then p else (k,v)::p in

    let platformdata = vm.platformdata |> default "acpi_s3" "0" |> default "acpi_s4" "0" in

    {
      Domain.ssidref = vm.ssidref;
      hvm = hvm;
      hap = hvm;
      name = vm.name;
      xsdata = vm.xsdata;
      platformdata = platformdata @ vcpus;
      bios_strings = vm.bios_strings;
      has_vendor_device = vm.has_vendor_device;
    }

  let create_exn (task: Xenops_task.task_handle) memory_upper_bound vm =
    let k = vm.Vm.id in
    with_xc_and_xs (fun xc xs ->
        (* Ensure the DB contains something for this VM - this is to avoid a race with the *)
        let _ = DB.update k (function
            | Some x ->
              debug "VM = %s; reloading stored domain-level configuration" vm.Vm.id;
              Some x
            | None -> begin
              debug "VM = %s; has no stored domain-level configuration, regenerating" vm.Vm.id;
               let persistent =
                 VmExtra.{ default_persistent_t with
                           (* version 1 and later distinguish VMs started in Lima and later versions of xenopsd
                              from those VMs started in pre-Lima versions that didn't have this version field *)
                           version = VmExtra.persistent_version_lima
                         ; ty = Some vm.ty
                         ; last_start_time = Unix.gettimeofday ()
                         ; domain_config = Some (VmExtra.domain_config_of_vm vm)
                         ; nomigrate = Platform.is_true
                               ~key:"nomigrate"
                               ~platformdata:vm.Xenops_interface.Vm.platformdata
                               ~default:false
                         ; nested_virt=Platform.is_true
                               ~key:"nested-virt"
                               ~platformdata:vm.Xenops_interface.Vm.platformdata
                               ~default:false
                         ; profile = profile_of ~vm
                         ; pci_msitranslate = vm.Vm.pci_msitranslate
                         ; pci_power_mgmt = vm.Vm.pci_power_mgmt
                 } in
               Some VmExtra.{persistent}
             end) in

         let _ = DB.update k (fun vmextra ->
           match vmextra with
           | Some VmExtra.{persistent} -> begin
             match persistent.VmExtra.domain_config with
             | Some dc -> Some VmExtra.{persistent}
             | None ->
                  (* This is the upgraded migration/resume case - we've stored some persistent data
                    but it was before we recorded emulation flags. Let's regenerate them now and
                    store them persistently *)
                begin (* Sanity check *)
                  match vm.Xenops_interface.Vm.ty with
                  | PVinPVH _ -> failwith "Invalid state! No domain_config persistently stored for PVinPVH domain";
                  | _ -> ()
                end;
                let domain_config = VmExtra.domain_config_of_vm vm in
                Some VmExtra.{persistent={persistent with domain_config = Some domain_config }}
             end
           | None -> failwith "Interleaving problem") in

         let VmExtra.{persistent} = DB.read_exn vm.Vm.id in

         let shadow_multiplier = match vm.Vm.ty with
           | Vm.HVM { Vm.shadow_multiplier = sm } -> sm
           | _ -> 1.
         in
         let open Memory in
         let overhead_bytes =
           compute_overhead persistent vm.vcpu_max vm.memory_static_max shadow_multiplier
         in
         let resuming = persistent.VmExtra.suspend_memory_bytes <> 0L in
         (* If we are resuming then we know exactly how much memory is needed. If we are
               live migrating then we will only know an upper bound. If we are starting from
               scratch then we have a free choice. *)
         let min_bytes, max_bytes = match memory_upper_bound with
           | Some x ->
             debug "VM = %s; using memory_upper_bound = %Ld" vm.Vm.id x;
             x, x
           | None ->
             if resuming then begin
               debug "VM = %s; using stored suspend_memory_bytes = %Ld" vm.Vm.id persistent.VmExtra.suspend_memory_bytes;
               persistent.VmExtra.suspend_memory_bytes, persistent.VmExtra.suspend_memory_bytes
             end else begin
               debug "VM = %s; using memory_dynamic_min = %Ld and memory_dynamic_max = %Ld" vm.Vm.id vm.memory_dynamic_min vm.memory_dynamic_max;
               vm.memory_dynamic_min, vm.memory_dynamic_max
             end in
         let min_kib = kib_of_bytes_used (min_bytes +++ overhead_bytes)
         and max_kib = kib_of_bytes_used (max_bytes +++ overhead_bytes) in
         (* XXX: we would like to be able to cancel an in-progress with_reservation *)
         let dbg = Xenops_task.get_dbg task in


         Mem.with_reservation dbg min_kib max_kib
           (fun target_plus_overhead_kib reservation_id ->
              let domain_config, persistent =
                match persistent.VmExtra.domain_config with
                | Some dc -> dc, persistent
                | None ->
                  (* This is the upgraded migration/resume case - we've stored some persistent data
                    but it was before we recorded emulation flags. Let's regenerate them now and
                    store them persistently *)
                  begin (* Sanity check *)
                    match vm.Xenops_interface.Vm.ty with
                    | PVinPVH _ -> failwith "Invalid state! No domain_config persistently stored for PVinPVH domain";
                    | _ -> ()
                  end;
                  let domain_config = VmExtra.domain_config_of_vm vm in
                  let persistent = VmExtra.{persistent with domain_config = Some domain_config } in
                  (domain_config, persistent)
              in
              let create_info = generate_create_info ~xc ~xs vm persistent in
              let domid = Domain.make ~xc ~xs create_info vm.vcpu_max domain_config (uuid_of_vm vm) in
              Mem.transfer_reservation_to_domain dbg domid reservation_id;
              begin match vm.Vm.ty with
                | Vm.HVM { Vm.qemu_stubdom = true } ->
                  Mem.with_reservation dbg Stubdom.memory_kib Stubdom.memory_kib
                    (fun _ reservation_id ->
                       let stubdom_domid = Stubdom.create ~xc ~xs domid in
                       Mem.transfer_reservation_to_domain dbg stubdom_domid reservation_id;
                       set_stubdom ~xs domid stubdom_domid;
                    )
                | _ ->
                  ()
              end;
              let initial_target =
                let target_plus_overhead_bytes = bytes_of_kib target_plus_overhead_kib in
                let target_bytes = target_plus_overhead_bytes --- overhead_bytes in
                min vm.memory_dynamic_max target_bytes in
              set_initial_target ~xs domid (Int64.div initial_target 1024L);

              if vm.suppress_spurious_page_faults
              then Domain.suppress_spurious_page_faults ~xc domid;
              Domain.set_machine_address_size ~xc domid vm.machine_address_size;
              for i = 0 to vm.vcpu_max - 1 do
                Device.Vcpu.add ~xs ~dm:(dm_of ~vm) ~devid:i domid (i < vm.vcpus)
              done;
              set_domain_type ~xs domid vm;
           )
    )
  let create = create_exn

  let on_domain f (task: Xenops_task.task_handle) vm =
    let uuid = uuid_of_vm vm in
    with_xc_and_xs
      (fun xc xs ->
         match di_of_uuid ~xc ~xs uuid with
         | None -> raise (Xenopsd_error (Does_not_exist("domain", vm.Vm.id)))
         | Some di -> f xc xs task vm di
      )

  let on_domain_if_exists f (task: Xenops_task.task_handle) vm =
    try
      on_domain f task vm
    with Xenopsd_error (Does_not_exist("domain", _)) ->
      debug "Domain for VM %s does not exist: ignoring" vm.Vm.id

  let add vm =
    with_xc_and_xs
      (fun xc xs ->
         match di_of_uuid ~xc ~xs (uuid_of_vm vm) with
         | None -> () (* Domain doesn't exist so no setup required *)
         | Some di ->
           debug "VM %s exists with domid=%d; checking whether xenstore is intact" vm.Vm.id di.Xenctrl.domid;
           (* Minimal set of keys and values expected by tools like xentop (CA-24231) *)
           let minimal_local_kvs = [
             "name", vm.Vm.name;
             "domid", string_of_int di.Xenctrl.domid;
             "vm", "/vm/" ^ vm.Vm.id;
             "memory/dynamic-min", Int64.(to_string (div vm.Vm.memory_dynamic_min 1024L));
             "memory/target", Int64.(to_string (div vm.Vm.memory_dynamic_min 1024L));
             "memory/dynamic-max", Int64.(to_string (div vm.Vm.memory_dynamic_max 1024L))
           ] |> List.map (fun (k, v) -> Printf.sprintf "/local/domain/%d/%s" di.Xenctrl.domid k, v) in
           let minimal_vm_kvs = [
             "uuid", vm.Vm.id;
             "name", vm.Vm.name;
             Printf.sprintf "domains/%d" di.Xenctrl.domid, Printf.sprintf "/local/domain/%d" di.Xenctrl.domid;
             Printf.sprintf "domains/%d/create-time" di.Xenctrl.domid, "0"
           ] |> List.map (fun (k, v) -> Printf.sprintf "/vm/%s/%s" vm.Vm.id k, v) in
           List.iter
             (fun (k, v) ->
                if try ignore(xs.Xs.read k); false with _ -> true then begin
                  debug "xenstore-write %s <- %s" k v;
                  xs.Xs.write k v
                end
             ) (minimal_local_kvs @ minimal_vm_kvs)
      )

  let rename vm vm' =
    with_xc_and_xs
      (fun xc xs ->
         match di_of_uuid ~xc ~xs (uuid_of_string vm) with
         | None -> ()
         | Some di ->
            begin
              debug "Renaming domain %d from %s to %s" di.Xenctrl.domid vm vm';
              Xenctrl.domain_sethandle xc di.Xenctrl.domid vm';
              debug "Moving xenstore tree";
              Domain.move_xstree xs di.Xenctrl.domid vm vm';

              DB.rename vm vm'
            end
      )

  let remove vm =
    with_xc_and_xs
      (fun xc xs ->
         safe_rm xs (Printf.sprintf "/vm/%s" vm.Vm.id);
         safe_rm xs (Printf.sprintf "/vss/%s" vm.Vm.id);
      );
    (* Best-effort attempt to remove metadata - if VM has been powered off
       * then it will have already been deleted by VM.destroy *)
    try DB.remove vm.Vm.id
    with Xenopsd_error (Does_not_exist("extra", _)) -> ()

  let log_exn_continue msg f x = try f x with e -> debug "Safely ignoring exception: %s while %s" (Printexc.to_string e) msg

  let destroy_device_model = on_domain_if_exists (fun xc xs task vm di ->
      let domid = di.Xenctrl.domid in
      let qemu_domid = Opt.default (this_domid ~xs) (get_stubdom ~xs domid) in
      log_exn_continue "Error stoping device-model, already dead ?"
        (fun () -> Device.Dm.stop ~xs ~qemu_domid ~dm:(dm_of ~vm) domid) ();
      log_exn_continue "Error stoping vncterm, already dead ?"
        (fun () -> Device.PV_Vnc.stop ~xs domid) ();
      (* If qemu is in a different domain to storage, detach disks *)
    )

  let destroy = on_domain_if_exists (fun xc xs task vm di -> finally (fun ()->
      let domid = di.Xenctrl.domid in
      let qemu_domid = Opt.default (this_domid ~xs) (get_stubdom ~xs domid) in
      (* We need to clean up the stubdom before the primary otherwise we deadlock *)
      Opt.iter
        (fun stubdom_domid ->
           Domain.destroy task ~xc ~xs ~qemu_domid ~dm:(dm_of ~vm) stubdom_domid
        ) (get_stubdom ~xs domid);

      let devices = Device_common.list_frontends ~xs domid in
      let vbds = List.filter (fun dev -> let open Device_common in match dev.frontend.kind with Vbd _ -> true | _ -> false) devices in
      let dps = List.map (fun device -> Device.Generic.get_private_key ~xs device _dp_id) vbds in

      (* Normally we throw-away our domain-level information. If the domain
         has suspended then we preserve it. *)
      if di.Xenctrl.shutdown && (Domain.shutdown_reason_of_int di.Xenctrl.shutdown_code = Domain.Suspend)
      then debug "VM = %s; domid = %d; domain has suspended; preserving domain-level information" vm.Vm.id di.Xenctrl.domid
      else begin
        debug "VM = %s; domid = %d; will not have domain-level information preserved" vm.Vm.id di.Xenctrl.domid;
        if DB.exists vm.Vm.id then DB.remove vm.Vm.id;
      end;
      Domain.destroy task ~xc ~xs ~qemu_domid ~dm:(dm_of ~vm) domid;
      (* Detach any remaining disks *)
      List.iter (fun dp ->
          try
            Storage.dp_destroy task dp
          with e ->
            warn "Ignoring exception in VM.destroy: %s" (Printexc.to_string e)) dps
    )
      (fun ()->
         (* Finally, discard any device caching for the domid destroyed *)
         DeviceCache.discard device_cache di.Xenctrl.domid;
         Device.(Qemu.SignalMask.unset Qemu.signal_mask di.Xenctrl.domid);
      )
    )

  let pause = on_domain (fun xc xs _ _ di ->
      if di.Xenctrl.total_memory_pages = 0n then raise (Xenopsd_error Domain_not_built);
      Domain.pause ~xc di.Xenctrl.domid
    )

  let unpause = on_domain (fun xc xs _ _ di ->
      if di.Xenctrl.total_memory_pages = 0n then raise (Xenopsd_error Domain_not_built);
      Domain.unpause ~xc di.Xenctrl.domid;
      Opt.iter
        (fun stubdom_domid ->
           Domain.unpause ~xc stubdom_domid
        ) (get_stubdom ~xs di.Xenctrl.domid)
    )

  let set_xsdata task vm xsdata = on_domain (fun xc xs _ _ di ->
      Domain.set_xsdata ~xs di.Xenctrl.domid xsdata
    ) task vm

  let set_vcpus task vm target = on_domain (fun xc xs _ _ di ->
      let domid = di.Xenctrl.domid in
      (* Returns the instantaneous CPU number from xenstore *)
      let current =
        let n = ref (-1) in
        for i = 0 to vm.Vm.vcpu_max - 1
        do if Device.Vcpu.status ~xs ~dm:(dm_of ~vm) ~devid:i domid then n := i
        done;
        !n + 1 in

      if current > target then (
        (* need to deplug cpus *)
        for i = current - 1 downto target
        do
          Device.Vcpu.set ~xs ~dm:(dm_of ~vm) ~devid:i domid false
        done
      ) else if current < target then (
        (* need to plug cpus *)
        for i = current to (target - 1)
        do
          Device.Vcpu.set ~xs ~dm:(dm_of ~vm) ~devid:i domid true
        done
      )
    ) task vm

  let set_shadow_multiplier task vm target = on_domain (fun xc xs _ _ di ->
      if get_domain_type ~xs di = Vm.Domain_PV then raise (Xenopsd_error (Unimplemented "shadow_multiplier for PV domains"));
      let domid = di.Xenctrl.domid in
      let static_max_mib = Memory.mib_of_bytes_used vm.Vm.memory_static_max in
      let newshadow = Int64.to_int (Memory.HVM.shadow_mib static_max_mib vm.Vm.vcpu_max target) in
      let curshadow = Xenctrl.shadow_allocation_get xc domid in
      let needed_mib = newshadow - curshadow in
      debug "VM = %s; domid = %d; Domain has %d MiB shadow; an increase of %d MiB requested" vm.Vm.id domid curshadow needed_mib;
      if not(Domain.wait_xen_free_mem xc (Int64.mul (Int64.of_int needed_mib) 1024L)) then begin
        error "VM = %s; domid = %d; Failed waiting for Xen to free %d MiB: some memory is not properly accounted" vm.Vm.id domid needed_mib;
        raise (Xenopsd_error (Not_enough_memory (Memory.bytes_of_mib (Int64.of_int needed_mib))))
      end;
      debug "VM = %s; domid = %d; shadow_allocation_setto %d MiB" vm.Vm.id domid newshadow;
      Xenctrl.shadow_allocation_set xc domid newshadow;
    ) task vm

  let set_memory_dynamic_range task vm min max = on_domain (fun xc xs _ _ di ->
      let domid = di.Xenctrl.domid in
      Domain.set_memory_dynamic_range ~xc ~xs
        ~min:(Int64.to_int (Int64.div min 1024L))
        ~max:(Int64.to_int (Int64.div max 1024L))
        domid;
      Mem.balance_memory (Xenops_task.get_dbg task)
    ) task vm

  let qemu_device_of_vbd_frontend = function
    | Empty  -> ""
    | Name x -> x
    | Nbd Storage_interface.{ uri } -> uri
    | Device device -> Device_common.block_device_of_device device

  (* NB: the arguments which affect the qemu configuration must be saved and
     restored with the VM. *)
  let create_device_model_config vm vmextra vbds vifs vgpus vusbs = match vmextra.VmExtra.persistent with
    | { VmExtra.build_info = None }
    | { VmExtra.ty = None } -> raise (Xenopsd_error Domain_not_built)
    | {
      VmExtra.build_info = Some build_info;
      ty = Some ty;
      VmExtra.qemu_vbds = qemu_vbds;
    } ->
      let make ?(boot_order="cd") ?(serial="pty") ?(monitor="null")
          ?(nics=[]) ?(disks=[]) ?(vgpus=[])
          ?(pci_emulations=[]) ?(usb=Device.Dm.Disabled)
          ?(parallel=None)
          ?(acpi=true) ?(video=Cirrus) ?keymap
          ?vnc_ip ?(pci_passthrough=false) ?(hvm=true) ?(video_mib=4) () =
        let video = match video, vgpus with
          | Cirrus, [] -> Device.Dm.Cirrus
          | Standard_VGA, [] -> Device.Dm.Std_vga
          | IGD_passthrough GVT_d, [] -> Device.Dm.GVT_d
          | Vgpu, [] -> raise (Xenopsd_error (Internal_error "Vgpu mode specified but no vGPUs"))
          | Vgpu, vgpus -> Device.Dm.Vgpu vgpus
          | _ -> raise (Xenopsd_error (Internal_error "Invalid graphics mode"))
        in
        let open Device.Dm in {
          memory = build_info.Domain.memory_max;
          boot = boot_order;
          serial = Some serial;
          monitor = Some monitor;
          vcpus = build_info.Domain.vcpus; (* vcpus max *)
          vcpus_current = vm.Vm.vcpus;
          nics = nics;
          disks = disks;
          pci_emulations = pci_emulations;
          usb = usb;
          parallel = parallel;
          acpi = acpi;
          disp = VNC (video, vnc_ip, true, 0, keymap);
          pci_passthrough = pci_passthrough;
          video_mib=video_mib;
          extras = [];
        } in
      let nics = List.filter_map (fun vif ->
          match vif.Vif.backend with
          | Network.Local b | Network.Remote (_, b) ->
            Some (vif.Vif.mac, b, vif.Vif.position)
          | Network.Sriov _ -> None
        ) vifs in
      match ty with
      | PV { framebuffer = false } -> None
      | PV { framebuffer = true; framebuffer_ip=Some vnc_ip } ->
        Some (make ~hvm:false ~vnc_ip ())
      | PV { framebuffer = true; framebuffer_ip=None } ->
        Some (make ~hvm:false ())
      | PVinPVH { framebuffer = false } -> None
      | PVinPVH { framebuffer = true; framebuffer_ip=Some vnc_ip } ->
        Some (make ~hvm:true ~vnc_ip ())
      | PVinPVH { framebuffer = true; framebuffer_ip=None } ->
        Some (make ~hvm:true ())
      | HVM hvm_info ->
        let disks = List.filter_map (fun vbd ->
            let id = vbd.Vbd.id in
            if (List.mem_assoc id qemu_vbds)
            then
              let index, bd = List.assoc id qemu_vbds in
              let path = qemu_device_of_vbd_frontend bd in
              match vbd.Vbd.ty, vbd.mode with
              | Vbd.Disk, ReadOnly -> None
              | Vbd.Disk, _        -> Some (index, path, Device.Dm.Disk)
              | _                  -> Some (index, path, Device.Dm.Cdrom)
            else None
          ) vbds in
        let usb_enabled =
          try (List.assoc "usb" vm.Vm.platformdata) = "true"
          with Not_found -> true
        in
        let usb_tablet_enabled =
          try (List.assoc "usb_tablet" vm.Vm.platformdata) = "true"
          with Not_found -> true
        in
        let usb =
          match usb_enabled, usb_tablet_enabled with
          | true, false -> Device.Dm.Enabled []
          | true, true -> Device.Dm.Enabled [("tablet", 2)]
          | false, _ -> Device.Dm.Disabled
        in
        let parallel =
          if (List.mem_assoc "parallel" vm.Vm.platformdata)
          then Some (List.assoc "parallel" vm.Vm.platformdata)
          else None in
        Some (make ~video_mib:hvm_info.video_mib
                ~video:hvm_info.video ~acpi:hvm_info.acpi
                ?serial:hvm_info.serial ?keymap:hvm_info.keymap
                ?vnc_ip:hvm_info.vnc_ip ~usb ~parallel
                ~pci_emulations:hvm_info.pci_emulations
                ~pci_passthrough:hvm_info.pci_passthrough
                ~boot_order:hvm_info.boot_order ~nics ~disks ~vgpus ())

  let clean_memory_reservation task domid =
    try
      let dbg = Xenops_task.get_dbg task in
      let reservation_id = Mem.query_reservation_of_domain dbg domid in
      Mem.delete_reservation dbg (reservation_id, None)
    with Memory_interface.MemoryError Memory_interface.No_reservation ->
      error "Please check if memory reservation for domain %d is present, if so manually remove it" domid

  let build_domain_exn xc xs domid task vm vbds vifs vgpus vusbs extras force =
    let open Memory in
    let initial_target = get_initial_target ~xs domid in
    let static_max_kib = vm.memory_static_max /// 1024L in
    let static_max_mib = static_max_kib /// 1024L in
    let make_build_info kernel priv = {
      Domain.memory_max = static_max_kib;
      memory_target = initial_target;
      kernel = kernel;
      vcpus = vm.vcpu_max;
      priv = priv;
    } in
    debug "static_max_mib=%Ld" static_max_mib;
    let pvinpvh_xen_cmdline =
      let base =
        try List.assoc "pvinpvh-xen-cmdline" vm.Vm.platformdata
        with Not_found -> !Xenopsd.pvinpvh_xen_cmdline
      in
      let shim_mem =
        let shim_mib = PVinPVH_memory_model_data.shim_mib static_max_mib in
        Printf.sprintf "shim_mem=%LdM" shim_mib
      in
      String.concat " " [base; shim_mem]
    in
    (* We should prevent leaking files in our filesystem *)
    let kernel_to_cleanup = ref None in
    finally (fun () ->
        let (build_info, timeoffset) =
          match vm.ty with
          | HVM hvm_info ->
            let builder_spec_info = Domain.BuildHVM {
                Domain.shadow_multiplier = hvm_info.shadow_multiplier;
                video_mib = hvm_info.video_mib;
              } in
            ((make_build_info !Resources.hvmloader builder_spec_info), hvm_info.timeoffset)

          | PV { boot = Direct direct } ->
            let builder_spec_info = Domain.BuildPV {
                Domain.cmdline = direct.cmdline;
                ramdisk = direct.ramdisk;
              } in
            ((make_build_info direct.kernel builder_spec_info), "")
          | PV { boot = Indirect { devices = [] } } ->
            raise (Xenopsd_error No_bootable_device)
          | PV { boot = Indirect ( { devices = d :: _ } as i ) } ->
            with_disk ~xc ~xs task d false
              (fun dev ->
                 let b = Bootloader.extract task ~bootloader:i.bootloader
                     ~legacy_args:i.legacy_args ~extra_args:i.extra_args
                     ~pv_bootloader_args:i.bootloader_args
                     ~disk:dev ~vm:vm.Vm.id () in
                 kernel_to_cleanup := Some b;
                 let builder_spec_info = Domain.BuildPV {
                     Domain.cmdline = b.Bootloader.kernel_args;
                     ramdisk = b.Bootloader.initrd_path;
                   } in
                 ((make_build_info b.Bootloader.kernel_path builder_spec_info), "")
              )
          | PVinPVH { boot = Direct direct } ->
            debug "Checking xen cmdline";
            let builder_spec_info = Domain.BuildPVH Domain.{
                cmdline = pvinpvh_xen_cmdline;
                modules = (direct.kernel, Some direct.cmdline) ::
                          (match direct.ramdisk with
                           | Some r -> [r, None]
                           | None -> []
                          );
                shadow_multiplier = 1.;
                video_mib = 4;
              } in
            ((make_build_info !Resources.pvinpvh_xen builder_spec_info), "")
          | PVinPVH { boot = Indirect { devices = [] } } ->
            raise (Xenopsd_error No_bootable_device)
          | PVinPVH { boot = Indirect ( { devices = d :: _ } as i ) } ->
            with_disk ~xc ~xs task d false
              (fun dev ->
                 let b = Bootloader.extract task ~bootloader:i.bootloader
                     ~legacy_args:i.legacy_args ~extra_args:i.extra_args
                     ~pv_bootloader_args:i.bootloader_args
                     ~disk:dev ~vm:vm.Vm.id () in
                 kernel_to_cleanup := Some b;
                 let builder_spec_info = Domain.BuildPVH Domain.{
                     cmdline = pvinpvh_xen_cmdline;
                     modules = (b.Bootloader.kernel_path, Some b.Bootloader.kernel_args) ::
                               (match b.Bootloader.initrd_path with
                                | Some r -> [r, None]
                                | None -> []
                               );
                     shadow_multiplier = 1.;
                     video_mib = 4;
                   } in
                 ((make_build_info !Resources.pvinpvh_xen builder_spec_info), "")
              ) in
        Domain.build task ~xc ~xs ~store_domid ~console_domid ~timeoffset ~extras ~vgpus build_info (choose_xenguest vm.Vm.platformdata) domid force;
        Int64.(
          let min = to_int (div vm.Vm.memory_dynamic_min 1024L)
          and max = to_int (div vm.Vm.memory_dynamic_max 1024L) in
          Domain.set_memory_dynamic_range ~xc ~xs ~min ~max domid
        );

        debug "VM = %s; domid = %d; Domain build completed" vm.Vm.id domid;
        let _ = DB.update_exn vm.Vm.id (fun d ->
            Some VmExtra.{persistent = { d.persistent with
                build_info = Some build_info;
                ty = Some vm.ty;
              }
            }
          )
        in ()
      ) (fun () -> Opt.iter Bootloader.delete !kernel_to_cleanup)


  let build_domain vm vbds vifs vgpus vusbs extras force xc xs task _ di =
    let domid = di.Xenctrl.domid in
    finally
      (fun () ->
         try
           build_domain_exn xc xs domid task vm vbds vifs vgpus vusbs extras force;
         with
         | Bootloader.Bad_sexpr x ->
           let m = Printf.sprintf "VM = %s; domid = %d; Bootloader.Bad_sexpr %s" vm.Vm.id domid x in
           debug "%s" m;
           raise (Xenopsd_error (Internal_error m))
         | Bootloader.Bad_error x ->
           let m = Printf.sprintf "VM = %s; domid = %d; Bootloader.Bad_error %s" vm.Vm.id domid x in
           debug "%s" m;
           raise (Xenopsd_error (Internal_error m))
         | Bootloader.Unknown_bootloader x ->
           let m = Printf.sprintf "VM = %s; domid = %d; Bootloader.Unknown_bootloader %s" vm.Vm.id domid x in
           debug "%s" m;
           raise (Xenopsd_error (Internal_error m))
         | Bootloader.Error_from_bootloader x ->
           let m = Printf.sprintf "VM = %s; domid = %d; Bootloader.Error_from_bootloader %s" vm.Vm.id domid x in
           debug "%s" m;
           raise (Xenopsd_error (Bootloader_error (vm.Vm.id, x)))
         | Domain.Not_enough_memory m ->
           debug "VM = %s; domid = %d; Domain.Not_enough_memory. Needed: %Ld bytes" vm.Vm.id domid m;
           raise (Xenopsd_error (Not_enough_memory m))
         | e ->
           let m = Printf.sprintf "VM = %s; domid = %d; Error: %s" vm.Vm.id domid (Printexc.to_string e) in
           debug "%s" m;
           raise e
      ) (fun () -> clean_memory_reservation task di.Xenctrl.domid)

  let build ?restore_fd task vm vbds vifs vgpus vusbs extras force = on_domain (build_domain vm vbds vifs vgpus vusbs extras force) task vm

  let create_device_model_exn vbds vifs vgpus vusbs saved_state xc xs task vm di =
    let vmextra = DB.read_exn vm.Vm.id in
    let qemu_dm = dm_of ~vm in
    let xenguest = choose_xenguest vm.Vm.platformdata in
    debug "chosen qemu_dm = %s" (Device.Profile.wrapper_of qemu_dm);
    debug "chosen xenguest = %s" xenguest;
    try
      Opt.iter (fun info ->
          match vm.Vm.ty with
          | Vm.HVM { Vm.qemu_stubdom = true } ->
            if saved_state then failwith "Cannot resume with stubdom yet";
            Opt.iter
              (fun stubdom_domid ->
                 Stubdom.build task ~xc ~xs ~dm:qemu_dm ~store_domid ~console_domid info xenguest di.Xenctrl.domid stubdom_domid;
                 Device.Dm.start_vnconly task ~xs ~dm:qemu_dm info stubdom_domid
              ) (get_stubdom ~xs di.Xenctrl.domid);
          | Vm.HVM { Vm.qemu_stubdom = false } ->
            (if saved_state then Device.Dm.restore else Device.Dm.start)
              task ~xs ~dm:qemu_dm info di.Xenctrl.domid
          | Vm.PV _ ->
            Device.Vfb.add ~xc ~xs di.Xenctrl.domid;
            Device.Vkbd.add ~xc ~xs di.Xenctrl.domid;
            Device.Dm.start_vnconly task ~xs ~dm:qemu_dm info di.Xenctrl.domid
          | Vm.PVinPVH _ ->
            Device.Vfb.add ~xc ~xs di.Xenctrl.domid;
            Device.Vkbd.add ~xc ~xs di.Xenctrl.domid;
            Device.Dm.start_vnconly task ~xs ~dm:qemu_dm info di.Xenctrl.domid
        ) (create_device_model_config vm vmextra vbds vifs vgpus vusbs);
      match vm.Vm.ty with
      | Vm.PV { vncterm = true; vncterm_ip = ip }
      | Vm.PVinPVH { vncterm = true; vncterm_ip = ip } ->
        Device.PV_Vnc.start ~xs ?ip di.Xenctrl.domid
      | _ -> ()
    with Device.Ioemu_failed (name, msg) ->
      raise (Xenopsd_error (Failed_to_start_emulator (vm.Vm.id, name, msg)))

  let create_device_model task vm vbds vifs vgpus vusbs saved_state = on_domain (create_device_model_exn vbds vifs vgpus vusbs saved_state) task vm

  let request_shutdown task vm reason ack_delay =
    let reason = shutdown_reason reason in
    on_domain
      (fun xc xs task vm di ->
         let domain_type =
           match get_domain_type ~xs di with
           | Vm.Domain_HVM -> `hvm
           | Vm.Domain_PV -> `pv
           | Vm.Domain_PVinPVH -> `pvh
           | Vm.Domain_undefined -> failwith "undefined domain type: cannot save"
         in

         let domid = di.Xenctrl.domid in
         try
           Domain.shutdown ~xc ~xs domid reason;
           Domain.shutdown_wait_for_ack task ~timeout:ack_delay ~xc ~xs domid domain_type reason;
           true
         with Watch.Timeout _ ->
           false
      ) task vm

  let wait_shutdown task vm reason timeout =
    event_wait internal_updates task timeout
      (function
        | Dynamic.Vm id when id = vm.Vm.id ->
          debug "EVENT on our VM: %s" id;
          on_domain (fun xc xs _ vm di -> di.Xenctrl.shutdown) task vm
        | Dynamic.Vm id ->
          debug "EVENT on other VM: %s" id;
          false
        | _ ->
          debug "OTHER EVENT";
          false)

  (* Mount a filesystem somewhere, with optional type *)
  let mount ?ty:(ty = None) src dest write =
    let ty = match ty with None -> [] | Some ty -> [ "-t"; ty ] in
    run !Xc_resources.mount (ty @ [ src; dest; "-o"; if write then "rw" else "ro" ]) |> ignore_string

  let timeout = 300. (* 5 minutes: something is seriously wrong if we hit this timeout *)
  exception Umount_timeout

  (** Unmount a mountpoint. Retries every 5 secs for a total of 5mins before returning failure *)
  let umount ?(retry=true) dest =
    let finished = ref false in
    let start = Unix.gettimeofday () in

    while not(!finished) && (Unix.gettimeofday () -. start < timeout) do
      try
        run !Xc_resources.umount [dest] |> ignore_string;
        finished := true
      with e ->
        if not(retry) then raise e;
        debug "Caught exception (%s) while unmounting %s: pausing before retrying"
          (Printexc.to_string e) dest;
        Thread.delay 5.
    done;
    if not(!finished) then raise Umount_timeout

  let with_mounted_dir_ro device f =
    let mount_point = Filename.temp_file "xenops_mount_" "" in
    Unix.unlink mount_point;
    Unix.mkdir mount_point 0o640;
    finally
      (fun () ->
         mount ~ty:(Some "ext2") device mount_point false;
         f mount_point)
      (fun () ->
         (try umount mount_point with e -> debug "Caught %s" (Printexc.to_string e));
         (try Unix.rmdir mount_point with e -> debug "Caught %s" (Printexc.to_string e))
      )

  (** open a file, and make sure the close is always done *)
  let with_data ~xc ~xs task data write f = match data with
    | Disk disk ->
      with_disk ~xc ~xs task disk write (fun path ->
          let with_fd_of_path p f =
            let is_raw_image =
              Unixext.with_file path [Unix.O_RDONLY] 0o400 (fun fd ->
                  match Suspend_image.read_save_signature fd with
                  | `Ok _ -> true | _ -> false
                )
            in
            match (write, is_raw_image) with
            | true, _ -> (* Always write raw *)
              Unixext.with_file path [Unix.O_WRONLY; Unix.O_APPEND] 0o600 f
            | false, true -> (* We're reading raw *)
              Unixext.with_file path [Unix.O_RDONLY] 0o600 f
            | false, false -> (* Assume reading from filesystem *)
              with_mounted_dir_ro p (fun dir ->
                  let filename = dir ^ "/suspend-image" in
                  Unixext.with_file filename [Unix.O_RDONLY] 0o600 f
                )
          in
          with_fd_of_path path (fun fd ->
              finally
                (fun () -> f fd)
                (fun () ->
                   try Xapi_stdext_unix.Unixext.fsync fd;
                   with Unix.Unix_error(Unix.EIO, _, _) ->
                     error "Caught EIO in fsync after suspend; suspend image may be corrupt";
                     raise (Xenopsd_error IO_error)
                )
            )
        )
    | FD fd -> f fd

  let wait_ballooning task vm =
    on_domain
      (fun xc xs _ _ di ->
         let domid = di.Xenctrl.domid in
         let balloon_active_path = xs.Xs.getdomainpath domid ^ "/control/balloon-active" in
         let balloon_active =
           try
             Some (xs.Xs.read balloon_active_path)
           with _ -> None
         in
         match balloon_active with
         (* Not currently ballooning *)
         | None | Some "0" -> ()
         (* Ballooning in progress, we need to wait *)
         | Some _ ->
           let watches = [ Watch.value_to_become balloon_active_path "0"
                         ; Watch.key_to_disappear balloon_active_path ]
           in
           (* raise Cancelled on task cancellation and Watch.Timeout on timeout *)
           try
             cancellable_watch (Domain domid) watches [] task ~xs ~timeout:!Xenopsd.additional_ballooning_timeout ()
             |> ignore
           with Watch.Timeout _ ->
             raise (Xenops_interface.Xenopsd_error Ballooning_timeout_before_migration)
      ) task vm

  let save task progress_callback vm flags data vgpu_data pre_suspend_callback =
    let flags' =
      List.map
        (function
          | Live -> Domain.Live
        ) flags in
    on_domain
      (fun xc xs (task:Xenops_task.task_handle) vm di ->
         let domain_type =
           match get_domain_type ~xs di with
           | Vm.Domain_HVM -> `hvm
           | Vm.Domain_PV -> `pv
           | Vm.Domain_PVinPVH -> `pvh
           | Vm.Domain_undefined -> failwith "undefined domain type: cannot save"
         in
         let domid = di.Xenctrl.domid in

         let qemu_domid = Opt.default (this_domid ~xs) (get_stubdom ~xs domid) in

         with_data ~xc ~xs task data true
           (fun fd ->
              let vm_str = Vm.sexp_of_t vm |> Sexplib.Sexp.to_string in
              let vgpu_fd =
                match vgpu_data with
                | Some (FD vgpu_fd) -> Some vgpu_fd
                | Some disk when disk = data -> Some fd (* Don't open the file twice *)
                | Some other_disk -> None (* We don't support this *)
                | None -> None
              in
              let manager_path = choose_emu_manager vm.Vm.platformdata in
              Domain.suspend task ~xc ~xs ~domain_type ~dm:(dm_of ~vm) ~progress_callback
                ~qemu_domid ~manager_path vm_str domid fd vgpu_fd flags'
                (fun () ->
                   (* SCTX-2558: wait more for ballooning if needed *)
                   wait_ballooning task vm;
                   pre_suspend_callback task;
                   if not(request_shutdown task vm Suspend 30.)
                   then raise (Xenopsd_error Failed_to_acknowledge_shutdown_request);
                   if not(wait_shutdown task vm Suspend 1200.)
                   then raise (Xenopsd_error (Failed_to_shutdown(vm.Vm.id, 1200.)));
                );
              (* Record the final memory usage of the domain so we know how
                 much to allocate for the resume *)
              let di = Xenctrl.domain_getinfo xc domid in
              let pages = Int64.of_nativeint di.Xenctrl.total_memory_pages in
              debug "VM = %s; domid = %d; Final memory usage of the domain = %Ld pages" vm.Vm.id domid pages;
              (* Flush all outstanding disk blocks *)

              let devices = Device_common.list_frontends ~xs domid in
              let vbds = List.filter (fun dev -> match Device_common.(dev.frontend.kind) with Device_common.Vbd _ -> true | _ -> false) devices in
              List.iter (Device.Vbd.hard_shutdown_request ~xs) vbds;
              List.iter (Device.Vbd.hard_shutdown_wait task ~xs ~timeout:30.) vbds;
              debug "VM = %s; domid = %d; Disk backends have all been flushed" vm.Vm.id domid;
              List.iter (fun vbds_chunk ->
                  Stdext.Threadext.thread_iter (fun device ->
                      let backend =
                        match Rpcmarshal.unmarshal typ_of_backend (Device.Generic.get_private_key ~xs device _vdi_id |> Jsonrpc.of_string) with
                        | Ok x -> x
                        | Error (`Msg m) -> raise (Xenopsd_error (Internal_error (Printf.sprintf "Failed to unmarshal VBD backend: %s" m)))
                      in
                      let dp = Device.Generic.get_private_key ~xs device _dp_id in
                      match backend with
                      | None (* can never happen due to 'filter' above *)
                      | Some (Local _) -> ()
                      | Some (VDI path) ->
                        let sr, vdi = Storage.get_disk_by_name task path in
                        Storage.deactivate task dp sr vdi
                    ) vbds_chunk
                ) (Xenops_utils.chunks 10 vbds);
              debug "VM = %s; domid = %d; Storing final memory usage" vm.Vm.id domid;
              let _ = DB.update_exn vm.Vm.id (fun d ->
                  Some VmExtra.{persistent = { d.persistent with
                      suspend_memory_bytes = Memory.bytes_of_pages pages }
                  }
                )
              in ()
           )
      ) task vm

  let inject_igmp_query domid vifs =
    let vif_names = List.map (fun vif -> Printf.sprintf "vif%d.%d" domid vif.Vif.position) vifs in
    debug "Inject IGMP query to %s" (String.concat " " vif_names);
    (* Call script to inject IGMP query asynchronously *)
    let pid = Forkhelpers.safe_close_and_exec None None None [] !Xc_resources.igmp_query_injector_script ("--wait-vif-connected":: (string_of_int !Xenopsd.vif_ready_for_igmp_query_timeout) :: vif_names) in
    Forkhelpers.dontwaitpid pid

  let restore task progress_callback vm vbds vifs data vgpu_data extras =
    on_domain
      (fun xc xs task vm di ->
         finally
           (fun () ->
              let domid = di.Xenctrl.domid in
              let qemu_domid = Opt.default (this_domid ~xs) (get_stubdom ~xs domid) in
              let k = vm.Vm.id in
              let vmextra = DB.read_exn k in
              let (build_info, timeoffset) = match vmextra.VmExtra.persistent with
                | { VmExtra.build_info = None } ->
                  error "VM = %s; No stored build_info: cannot safely restore" vm.Vm.id;
                  raise (Xenopsd_error (Does_not_exist("build_info", vm.Vm.id)))
                | { VmExtra.build_info = Some x; VmExtra.ty } ->
                  let initial_target = get_initial_target ~xs domid in
                  let timeoffset = match ty with
                    | Some x -> (match x with HVM hvm_info -> hvm_info.timeoffset | _ -> "")
                    | _ -> "" in
                  ({ x with Domain.memory_target = initial_target }, timeoffset) in
              let no_incr_generationid = false in
              begin
                try
                  with_data ~xc ~xs task data false
                    (fun fd ->
                       let vgpu_fd =
                         match vgpu_data with
                         | Some (FD vgpu_fd) -> Some vgpu_fd
                         | Some disk when disk = data -> Some fd (* Don't open the file twice *)
                         | Some other_disk -> None (* We don't support this *)
                         | None -> None
                       in
                       let manager_path = choose_emu_manager vm.Vm.platformdata in
                       Domain.restore task ~xc ~xs ~dm:(dm_of vm)
                         ~store_domid ~console_domid ~no_incr_generationid (* XXX progress_callback *)
                         ~timeoffset ~extras build_info ~manager_path domid fd vgpu_fd
                    );
                with e ->
                  error "VM %s: restore failed: %s" vm.Vm.id (Printexc.to_string e);
                  (* As of xen-unstable.hg 779c0ef9682 libxenguest will destroy the domain on failure *)
                  if try ignore(Xenctrl.domain_getinfo xc di.Xenctrl.domid); false with _ -> true then begin
                    try
                      debug "VM %s: libxenguest has destroyed domid %d; cleaning up xenstore for consistency" vm.Vm.id di.Xenctrl.domid;
                      Domain.destroy task ~xc ~xs ~qemu_domid ~dm:(dm_of ~vm) di.Xenctrl.domid;
                    with e -> debug "Domain.destroy failed. Re-raising original error."
                  end;
                  raise e
              end;

              Int64.(
                let min = to_int (div vm.Vm.memory_dynamic_min 1024L)
                and max = to_int (div vm.Vm.memory_dynamic_max 1024L) in
                Domain.set_memory_dynamic_range ~xc ~xs ~min ~max domid
              );
              try
                inject_igmp_query domid vifs |> ignore
              with e ->
                error "VM %s: inject IGMP query failed: %s" vm.Vm.id (Printexc.to_string e)
           ) (fun () -> clean_memory_reservation task di.Xenctrl.domid)
      ) task vm

  let s3suspend =
    (* XXX: TODO: monitor the guest's response; track the s3 state *)
    on_domain
      (fun xc xs task vm di ->
         Domain.shutdown ~xc ~xs di.Xenctrl.domid Domain.S3Suspend
      )

  let s3resume =
    (* XXX: TODO: monitor the guest's response; track the s3 state *)
    on_domain
      (fun xc xs task vm di ->
         Domain.send_s3resume ~xc di.Xenctrl.domid
      )

  let get_state vm =
    let uuid = uuid_of_vm vm in
    let vme = vm.Vm.id |> DB.read in (* may not exist *)

    let map_tr f l = List.rev_map f l |> List.rev in

    with_xc_and_xs
      (fun xc xs ->
         match di_of_uuid ~xc ~xs uuid with
         | None ->
           (* XXX: we need to store (eg) guest agent info *)
           begin match vme with
             | Some vmextra when vmextra.VmExtra.persistent.VmExtra.suspend_memory_bytes = 0L ->
               halted_vm
             | Some _ ->
               { halted_vm with Vm.power_state = Suspended }
             | None ->
               halted_vm
           end
         | Some di ->
           let vnc = Opt.map (function
                 | Device.Socket.Port port -> { Vm.protocol = Vm.Rfb; port = port; path = "" }
                 | Device.Socket.Unix path -> { Vm.protocol = Vm.Rfb; port = 0 ; path = path })
               (Device.get_vnc_port ~xs ~dm:(dm_of ~vm) di.Xenctrl.domid) in
           let tc = Opt.map (fun port -> { Vm.protocol = Vm.Vt100; port = port; path = "" })
               (Device.get_tc_port ~xs di.Xenctrl.domid) in
           let local x = Printf.sprintf "/local/domain/%d/%s" di.Xenctrl.domid x in
           let uncooperative = try ignore_string (xs.Xs.read (local "memory/uncooperative")); true with Xs_protocol.Enoent _ -> false in
           let memory_target = try xs.Xs.read (local "memory/target") |> Int64.of_string |> Int64.mul 1024L with Xs_protocol.Enoent _ -> 0L in
           let memory_actual =
             let pages = Int64.of_nativeint di.Xenctrl.total_memory_pages in
             let kib = Xenctrl.pages_to_kib pages in
             Memory.bytes_of_kib kib in

           let memory_limit =
             (* The maximum amount of memory the domain can consume is the max of memory_actual
                and max_memory_pages (with our overheads subtracted). *)
             let max_memory_bytes =
               let overhead_bytes = Memory.bytes_of_mib (if di.Xenctrl.hvm_guest then Memory.HVM.xen_max_offset_mib else Memory.Linux.xen_max_offset_mib) in
               let raw_bytes = Memory.bytes_of_pages (Int64.of_nativeint di.Xenctrl.max_memory_pages) in
               Int64.sub raw_bytes overhead_bytes in
             (* CA-31764: may be larger than static_max if maxmem has been increased to initial-reservation. *)
             max memory_actual max_memory_bytes in

           let rtc = try xs.Xs.read (Printf.sprintf "/vm/%s/rtc/timeoffset" (Uuidm.to_string uuid)) with Xs_protocol.Enoent _ -> "" in
           let rec ls_lR root dir =
             let this = try [ dir, xs.Xs.read (root ^ "/" ^ dir) ] with _ -> [] in
             let subdirs = try xs.Xs.directory (root ^ "/" ^ dir) |> List.filter (fun x -> x <> "") |> map_tr (fun x -> dir ^ "/" ^ x) with _ -> [] in
             this @ (List.concat (map_tr (ls_lR root) subdirs)) in
           let guest_agent =
             [ "drivers"; "attr"; "data"; "control"; "feature"; "xenserver/attr" ]
             |> map_tr (ls_lR (Printf.sprintf "/local/domain/%d" di.Xenctrl.domid))
             |> List.concat
             |> map_tr (fun (k,v) -> (k,Xenops_utils.utf8_recode v))
           in
           let xsdata_state =
             Domain.allowed_xsdata_prefixes |> map_tr (ls_lR (Printf.sprintf "/local/domain/%d" di.Xenctrl.domid)) |> List.concat in
           let shadow_multiplier_target =
             if not di.Xenctrl.hvm_guest
             then 1.
             else begin
               try
                 let static_max_mib = Memory.mib_of_bytes_used vm.Vm.memory_static_max in
                 let default_shadow_mib = Memory.HVM.shadow_mib static_max_mib vm.Vm.vcpu_max 1. in
                 let actual_shadow_mib_int = Xenctrl.shadow_allocation_get xc di.Xenctrl.domid in
                 let actual_shadow_mib = Int64.of_int actual_shadow_mib_int in
                 let result = (Int64.to_float actual_shadow_mib) /. (Int64.to_float default_shadow_mib) in
                 (* CA-104562: Work around probable bug in bindings *)
                 if result > 1000.0 then begin
                   warn "CA-104562: Got value '%d' from shadow_allocation_get" actual_shadow_mib_int;
                   -1.0
                 end else result
               with e ->
                 warn "Caught exception in getting shadow allocation: %s" (Printexc.to_string e);
                 -1.0
             end
           in
           {
             Vm.power_state = if di.Xenctrl.paused then Paused else Running;
             domids = [ di.Xenctrl.domid ];
             consoles = Opt.to_list vnc @ (Opt.to_list tc);
             uncooperative_balloon_driver = uncooperative;
             guest_agent = guest_agent;
             pv_drivers_detected = begin match vme with
               | Some x -> x.VmExtra.persistent.VmExtra.pv_drivers_detected
               | None -> false
             end;
             xsdata_state = xsdata_state;
             vcpu_target = vm.vcpus;
             memory_target = memory_target;
             memory_actual = memory_actual;
             memory_limit = memory_limit;
             rtc_timeoffset = rtc;
             last_start_time = begin match vme with
               | Some x -> x.VmExtra.persistent.VmExtra.last_start_time
               | None -> 0.
             end;
             hvm = di.Xenctrl.hvm_guest;
             shadow_multiplier_target = shadow_multiplier_target;
             nomigrate = begin match vme with
               | None   -> false
               | Some x -> x.VmExtra.persistent.VmExtra.nomigrate
             end;
             nested_virt = begin match vme with
               | None   -> false
               | Some x -> x.VmExtra.persistent.VmExtra.nested_virt
             end;
             domain_type = get_domain_type ~xs di;
           }
      )

  let request_rdp vm enabled =
    let uuid = uuid_of_vm vm in
    with_xc_and_xs
      (fun xc xs ->
         match di_of_uuid ~xc ~xs uuid with
         | None -> raise (Xenopsd_error (Does_not_exist("domain", vm.Vm.id)))
         | Some di ->
           let path = Printf.sprintf "/local/domain/%d/control/ts" di.Xenctrl.domid in
           xs.Xs.write path (if enabled then "1" else "0")
      )

  let run_script task vm script =
    let uuid = uuid_of_vm vm in
    let domid, path =  with_xc_and_xs
        (fun xc xs ->
           match di_of_uuid ~xc ~xs uuid with
           | None -> raise (Xenopsd_error (Does_not_exist("domain", vm.Vm.id)))
           | Some di ->
             let path = xs.Xs.getdomainpath di.Xenctrl.domid in
             let _ =
               try xs.Xs.read (path ^ "/control/feature-xs-batcmd")
               with _ -> raise (Xenopsd_error (Unimplemented "run-script is not supported on the given VM (or it is still booting)")) in
             di.Xenctrl.domid, path ^ "/control/batcmd") in
    let () = with_xc_and_xs
        (fun xc xs ->
           let state = try xs.Xs.read (path ^ "/state") with _ -> "" in
           match state with
           | "" -> () (* state should normally be empty, unless in exceptional case e.g. xapi restarted previously *)
           | "IN PROGRESS" ->
             raise (Xenopsd_error (Failed_to_run_script "A residual run-script instance in progress, either wait for its completion or reboot the VM."))
           | _ ->
             info "Found previous run_script state %s leftover (either not started or completed), remove." state;
             xs.Xs.rm path) in
    let () = Xs.transaction ()
        (fun xs ->
           xs.Xs.write (path ^ "/script") script;
           xs.Xs.write (path ^ "/state") "READY") in
    let watch_succ = List.map
        (fun s -> Watch.map (fun _ -> ()) (Watch.value_to_become (path ^ "/state") s))
        [ "SUCCESS"; "TRUNCATED"; "FAILURE"] in
    let watch_fail = [Watch.key_to_disappear path] in
    let succ, flag, rc, stdout, stderr = Xs.with_xs (fun xs ->
        let succ = cancellable_watch (Domain domid) watch_succ watch_fail task ~xs ~timeout:86400. () in
        let flag = try xs.Xs.read (path ^ "/state") with _ -> "" in
        let rc = try xs.Xs.read (path ^ "/return") with _ -> "" in
        let stdout =  try xs.Xs.read (path ^ "/stdout") with _ -> "" in
        let stderr = try xs.Xs.read (path ^ "/stderr") with _ -> "" in
        xs.Xs.rm path;
        succ, flag, rc, stdout, stderr) in
    if not succ then Xenops_task.raise_cancelled task;
    let truncate s =
      let mark = " (truncated)" in
      let len = String.length s in
      if len >= 1024 || flag = "TRUNCATED" && len > 1024 - String.length mark
      then String.sub s 0 (1024 - String.length mark) ^ mark else s in
    let stdout, stderr = truncate stdout, truncate stderr in
    let rc_opt = try Some (Int64.of_string rc) with _ -> None in
    match flag, rc_opt with
    | ("SUCCESS" | "TRUNCATED"), Some rc_int  ->
      Rpc.Dict [("rc", Rpc.Int rc_int); ("stdout", Rpc.String stdout); ("stderr", Rpc.String stderr)]
    | _, _ ->
      raise (Xenopsd_error (Failed_to_run_script (Printf.sprintf "flag = %s, rc = %s, stdour = %s, stderr = %s" flag rc stdout stderr)))

  let set_domain_action_request vm request =
    let uuid = uuid_of_vm vm in
    with_xc_and_xs
      (fun xc xs ->
         match di_of_uuid ~xc ~xs uuid with
         | None -> raise (Xenopsd_error (Does_not_exist("domain", vm.Vm.id)))
         | Some di ->
           Domain.set_action_request ~xs di.Xenctrl.domid (match request with
               | None -> None
               | Some Needs_poweroff -> Some "poweroff"
               | Some Needs_reboot -> Some "reboot"
               | _ ->
                 error "VM = %s; Unknown domain action requested. Will set to poweroff" vm.Vm.id;
                 Some "poweroff"
             )
      )

  let get_domain_action_request vm =
    let uuid = uuid_of_vm vm in
    with_xc_and_xs
      (fun xc xs ->
         match di_of_uuid ~xc ~xs uuid with
         | None -> Some Needs_poweroff
         | Some d ->
           if d.Xenctrl.shutdown
           then Some (match d.Xenctrl.shutdown_code with
               | 0 -> Needs_poweroff
               | 1 -> Needs_reboot
               | 2 -> Needs_suspend
               | 3 -> Needs_crashdump
               | 4 -> Needs_reboot
               | _ -> Needs_poweroff) (* unexpected *)
           else begin match Domain.get_action_request ~xs d.Xenctrl.domid with
             | Some "poweroff" -> Some Needs_poweroff
             | Some "reboot" -> Some Needs_reboot
             | Some x ->
               error "VM = %s; Unknown domain action requested (%s). Will poweroff" vm.Vm.id x;
               Some Needs_poweroff
             | None -> None
           end
      )

  let get_internal_state vdi_map vif_map vm =
    let state = DB.read_exn vm.Vm.id in
    state.VmExtra.persistent |> rpc_of VmExtra.persistent_t |> Jsonrpc.to_string

  let set_internal_state vm state =
    let k = vm.Vm.id in
    let persistent = match Rpcmarshal.unmarshal VmExtra.typ_of_persistent_t (state |> Jsonrpc.of_string) with
      | Ok p -> p
      | Error (`Msg m) -> raise (Xenopsd_error (Internal_error (Printf.sprintf "Failed to unmarshal persistent_t: %s" m)))
    in
    (* Don't take the timeoffset from [state] (last boot record). Put back
       * the one from [vm] which came straight from the platform keys. *)
    let persistent = match vm.ty with
      | HVM {timeoffset} ->
        begin match persistent.VmExtra.ty with
          | Some (HVM hvm_info) ->
            {persistent with VmExtra.ty = Some (HVM {hvm_info with timeoffset = timeoffset})}
          | _ ->
            persistent
        end
      | _ -> persistent
    in
    let persistent = { persistent with VmExtra.profile = profile_of ~vm }
      |> DB.revision_of k
    in
    persistent |> rpc_of VmExtra.persistent_t |> Jsonrpc.to_string |> fun state_new ->
      debug "vm %s: persisting metadata %s" k state_new;
      (if state_new <> state then debug "vm %s: different original metadata %s" k state)
    ;
    let _ = DB.update vm.Vm.id (fun d -> Some VmExtra.{persistent})
    in ()

  let minimum_reboot_delay = 120.
end

let on_frontend f frontend =
  with_xc_and_xs
    (fun xc xs ->
       let frontend_di = match frontend |> uuid_of_string |> di_of_uuid ~xc ~xs with
         | None -> raise (Xenopsd_error (Does_not_exist ("domain", frontend)))
         | Some x -> x in
       f xc xs frontend_di.Xenctrl.domid (VM.get_domain_type ~xs frontend_di)
    )

module PCI = struct
  open Pci

  let id_of pci = snd pci.id

  let get_state' vm pci_addr =
    with_xc_and_xs
      (fun xc xs ->
         let all = match domid_of_uuid ~xc ~xs (uuid_of_string vm) with
           | Some domid -> Device.PCI.list ~xs domid |> List.map snd
           | None -> [] in
         {
           plugged = List.mem pci_addr all
         }
      )

  let get_state vm pci =
    get_state' vm pci.address

  let get_device_action_request vm pci =
    let state = get_state vm pci in
    (* If it has disappeared from xenstore then we assume unplug is needed if only
       to release resources/ deassign devices *)
    if not state.plugged then Some Needs_unplug else None

  let plug task vm pci =
    on_frontend
      (fun xc xs frontend_domid _ ->
         (* Make sure the backend defaults are set *)
         let vm_t = DB.read_exn vm in
         let persistent = vm_t.VmExtra.persistent in
         xs.Xs.write
           (Printf.sprintf "/local/domain/0/backend/pci/%d/0/msitranslate" frontend_domid)
           (if persistent.VmExtra.pci_msitranslate then "1" else "0");
         xs.Xs.write
           (Printf.sprintf "/local/domain/0/backend/pci/%d/0/power_mgmt" frontend_domid)
           (if persistent.VmExtra.pci_power_mgmt then "1" else "0");

         if not (Sys.file_exists "/sys/bus/pci/drivers/pciback") then begin
           error "PCIBack has not been loaded";
           raise (Xenopsd_error PCIBack_not_loaded);
         end;

         Device.PCI.bind [ pci.address ] Device.PCI.Pciback;
         Device.PCI.add xs [ pci.address ] frontend_domid
      ) vm

  let unplug task vm pci =
    (* We don't currently need to do anything here. Any necessary cleanup happens
     * in Domain.destroy. *)
    ()

end

module VGPU = struct
  open Vgpu

  let id_of vgpu = snd vgpu.id

  let start task vm vgpu saved_state =
    on_frontend
      (fun _ xs frontend_domid _ ->
         let vmextra = DB.read_exn vm in
         let vcpus = match vmextra.VmExtra.persistent with
           | { VmExtra.build_info = None } ->
             error "VM = %s; No stored build_info: cannot safely restore" vm;
             raise (Xenopsd_error (Does_not_exist("build_info", vm)))
           | { VmExtra.build_info = Some build_info } ->
             build_info.Domain.vcpus
         in
         Device.Dm.restore_vgpu task ~xs frontend_domid vgpu vcpus
      ) vm

  let get_state vm vgpu =
    on_frontend
      (fun _ xs frontend_domid _ ->
         let emulator_pid =
           match vgpu.implementation with
           | Empty
           | MxGPU _
           | GVT_g _ -> Device.Qemu.pid ~xs frontend_domid
           | Nvidia _ -> Device.Vgpu.pid ~xs frontend_domid
         in
         match emulator_pid with
         | Some pid -> {plugged = true; emulator_pid}
         | None -> {plugged = false; emulator_pid})
      vm
end

module VUSB = struct
  open Vusb

  let id_of vusb = snd vusb.id

  let get_state vm vusb =
    on_frontend
      (fun _ xs frontend_domid _ ->
         let emulator_pid = Device.Qemu.pid ~xs frontend_domid in
         debug "Qom list to get vusb state";
         let peripherals = Device.Vusb.qom_list ~xs ~domid:frontend_domid in
         let found = List.mem (snd vusb.Vusb.id)  peripherals in
         match emulator_pid, found with
         | Some pid, true -> {plugged = true}
         | _,_ -> {plugged = false})
      vm

  let get_device_action_request vm vusb =
    let state = get_state vm vusb in
    (* If it has disappeared from qom-list then we assume unplug is needed if only
       to release resources *)
    if not state.plugged then Some Needs_unplug else None

  let is_privileged vm =
    let open Vm in
    let vmextra = DB.read_exn vm in
    (* When pci_passthrough is true, the qemu will be privileged mode*)
    match vmextra.VmExtra.persistent with
    | {
      VmExtra.build_info = Some build_info;
      ty = Some (HVM hvm_info);
    } -> hvm_info.pci_passthrough
    | _ -> false

  let plug task vm vusb =
    on_frontend
      (fun xc xs frontend_domid domain_type ->
         if domain_type <> Vm.Domain_HVM
         then info "VM = %s; USB passthrough is only supported for HVM guests" vm
         else
           let privileged = is_privileged vm in
           Device.Vusb.vusb_plug ~xs ~privileged ~domid:frontend_domid ~id:(snd vusb.Vusb.id) ~hostbus:vusb.Vusb.hostbus ~hostport:vusb.Vusb.hostport ~version:vusb.Vusb.version
      ) vm

  let unplug task vm vusb =
    try
      on_frontend
        (fun xc xs frontend_domid hvm ->
           let privileged = is_privileged vm in
           Device.Vusb.vusb_unplug ~xs ~privileged ~domid:frontend_domid ~id:(snd vusb.Vusb.id) ~hostbus:vusb.Vusb.hostbus ~hostport:vusb.Vusb.hostport
        ) vm
    with
    | (Xenopsd_error (Does_not_exist(_,_))) ->
      debug "VM = %s; VUSB = %s; Ignoring missing domain" vm (id_of vusb)
    | (Xenopsd_error Device_not_connected) ->
      debug "VM = %s; VUSB = %s; Ignoring missing device" vm (id_of vusb)

end

let set_active_device path active =
  with_xs
    (fun xs ->
       if active
       then xs.Xs.write path "1"
       else safe_rm xs path;
    )

module VBD = struct
  open Vbd

  let id_of vbd = snd vbd.id

  (* When we attach a VDI we remember the attach result so we can lookup
     details such as the device-kind later. *)

  let vdi_attach_path vbd = Printf.sprintf "/xapi/%s/private/vdis/%s" (fst vbd.id) (snd vbd.id)

  let attach_and_activate task xc xs frontend_domid vbd vdi =
    let vdi = match vdi with
      | None ->
        (* XXX: do something better with CDROMs *)
        { domid = this_domid ~xs; attach_info = Storage_interface.{ implementations = [XenDisk {params="";extra=[];backend_type="vbd3"}; BlockDevice {path=""}] } }
      | Some (Local path) ->
        { domid = this_domid ~xs; attach_info = Storage_interface.{ implementations = [XenDisk {params=path;extra=[];backend_type="vbd3"}; BlockDevice {path}] } }
      | Some (VDI path) ->
        let sr, vdi = Storage.get_disk_by_name task path in
        let dp = Storage.id_of (string_of_int frontend_domid) vbd.id in
        let vm = fst vbd.id in
        Storage.attach_and_activate ~xc ~xs task vm dp sr vdi (vbd.mode = ReadWrite) in
    xs.Xs.write (vdi_attach_path vbd) (vdi |> rpc_of attached_vdi |> Jsonrpc.to_string);
    vdi

  let frontend_domid_of_device device = device.Device_common.frontend.Device_common.domid

  let device_number_of_device d =
    Device_number.of_xenstore_key d.Device_common.frontend.Device_common.devid

  let active_path vm vbd = Printf.sprintf "/vm/%s/devices/vbd/%s" vm (snd vbd.Vbd.id)

  let set_active task vm vbd active =
    try
      set_active_device (active_path vm vbd) active
    with e ->
      debug "set_active %s.%s <- %b failed: %s" (fst vbd.Vbd.id) (snd vbd.Vbd.id) active (Printexc.to_string e)

  let get_active vm vbd =
    try
      with_xs (fun xs -> xs.Xs.read (active_path vm vbd)) = "1"
    with _ -> false

  let epoch_begin task vm disk persistent = match disk with
    | VDI path ->
      let sr, vdi = Storage.get_disk_by_name task path in
      Storage.epoch_begin task sr vdi persistent
    | _ -> ()

  let epoch_end task vm disk = match disk with
    | VDI path ->
      let sr, vdi = Storage.get_disk_by_name task path in
      Storage.epoch_end task sr vdi
    | _ -> ()

  let _backend_kind = "backend-kind"

  let device_kind_of ~xs vbd =
    (* If the user has provided an override then use that *)
    if List.mem_assoc _backend_kind vbd.extra_backend_keys
    then Device_common.kind_of_string (List.assoc _backend_kind vbd.extra_backend_keys)
    else match (try Some(xs.Xs.read (vdi_attach_path vbd) |> Jsonrpc.of_string |> Rpcmarshal.unmarshal typ_of_attached_vdi) with _ -> None) with
      | None ->
        (* An empty VBD has to be a CDROM: anything will do *)
        Device_common.Vbd !Xenopsd.default_vbd_backend_kind
      | Some (Ok vdi) ->
        let _, xenstore_data, _ = params_of_backend vdi.attach_info in
        (* Use the storage manager's preference *)
        if List.mem_assoc _backend_kind xenstore_data
        then Device_common.kind_of_string (List.assoc _backend_kind xenstore_data)
        else Device_common.Vbd !Xenopsd.default_vbd_backend_kind
      | Some (Error (`Msg m)) ->
        raise (Xenopsd_error (Internal_error (Printf.sprintf "Error unmarshalling attached_vdi: %s" m)))
        
  let vdi_path_of_device ~xs device = Device_common.backend_path_of_device ~xs device ^ "/vdi"

  let plug task vm vbd =
    (* If the vbd isn't listed as "active" then we don't automatically plug this one in *)
    if not(get_active vm vbd)
    then debug "VBD %s.%s is not active: not plugging into VM" (fst vbd.Vbd.id) (snd vbd.Vbd.id)
    else on_frontend
        (fun xc xs frontend_domid domain_type ->
           if vbd.backend = None && domain_type <> Vm.Domain_HVM
           then info "VM = %s; an empty CDROM drive on PV and PVinPVH guests is simulated by unplugging the whole drive" vm
           else begin
             let vdi = attach_and_activate task xc xs frontend_domid vbd vbd.backend in
             let params, xenstore_data, extra_keys = params_of_backend vdi.attach_info in

             let new_keys = (List.map (fun (k, v) -> "sm-data/" ^ k, v) xenstore_data) @ extra_keys in
             let extra_backend_keys = List.fold_left (fun acc (k,v) ->
                 (k,v)::(List.remove_assoc k acc)) vbd.extra_backend_keys new_keys in

             let kind = device_kind_of ~xs vbd in

             (* Remember the VBD id with the device *)
             let vbd_id = _device_id kind, id_of vbd in
             (* Remember the VDI with the device (for later deactivation) *)
             let vdi_id = _vdi_id, vbd.backend |> rpc_of backend |> Jsonrpc.to_string in
             let dp_id = _dp_id, Storage.id_of (string_of_int frontend_domid) vbd.Vbd.id in
             let x = {
               Device.Vbd.mode = (match vbd.mode with
                   | ReadOnly -> Device.Vbd.ReadOnly
                   | ReadWrite -> Device.Vbd.ReadWrite
                 );
               device_number = vbd.position;
               phystype = Device.Vbd.Phys;
               params;
               dev_type = (match vbd.ty with
                   | CDROM -> Device.Vbd.CDROM
                   | Disk -> Device.Vbd.Disk
                   | Floppy -> Device.Vbd.Floppy
                 );
               unpluggable = vbd.unpluggable;
               protocol = None;
               kind;
               extra_backend_keys;
               extra_private_keys = dp_id :: vdi_id :: vbd_id :: vbd.extra_private_keys;
               backend_domid = vdi.domid;
             } in
             let dev =
               Xenops_task.with_subtask task (Printf.sprintf "Vbd.add %s" (id_of vbd))
                 (fun () -> Device.Vbd.add task ~xc ~xs ~hvm:(domain_type = Vm.Domain_HVM) x frontend_domid) in

             (* We store away the disk so we can implement VBD.stat *)
             Opt.iter (fun d -> xs.Xs.write (vdi_path_of_device ~xs dev) (d |> rpc_of disk |> Jsonrpc.to_string)) vbd.backend;

             (* NB now the frontend position has been resolved *)
             let open Device_common in
             let device_number = dev.frontend.devid |> Device_number.of_xenstore_key in

             (* If qemu is in a different domain to storage, attach disks to it *)
             let qemu_domid = Opt.default (this_domid ~xs) (get_stubdom ~xs frontend_domid) in
             let qemu_frontend = match Device_number.spec device_number with
               | Ide, n, _ when n < 4 ->
                 let index = Device_number.to_disk_number device_number in
                 begin match vbd.Vbd.backend with
                   | None   -> Some (index, Empty)
                   | Some _ -> Some (index, create_vbd_frontend ~xc ~xs task qemu_domid vdi)
                 end
               | _,_,_ -> None in
             (* Remember what we've just done *)
             (* Dom0 doesn't have a vm_t - we don't need this currently, but when we have storage driver domains,
                we will. Also this causes the SMRT tests to fail, as they demand the loopback VBDs *)
             Opt.iter (fun q ->
                 let _ = DB.update_exn vm (fun vm_t ->
                     Some VmExtra.{persistent = { vm_t.VmExtra.persistent with
                         qemu_vbds = (vbd.Vbd.id, q) :: vm_t.persistent.qemu_vbds }
                     }
                   )
                 in ()
               ) qemu_frontend
           end
        ) vm

  let unplug task vm vbd force =
    with_xc_and_xs
      (fun xc xs ->
         try
           (* On destroying the datapath:
              1. if the device has already been shutdown and deactivated (as in suspend) we
              must call DP.destroy here to avoid leaks
              2. if the device is successfully shutdown here then we must call DP.destroy
              because no-one else will
              3. if the device shutdown is rejected then we should leave the DP alone and
              rely on the event thread calling us again later.
              *)
           let domid = domid_of_uuid ~xc ~xs (uuid_of_string vm) in
           (* If the device is gone then we don't need to shut it down but we do need
              to free any storage resources. *)
           let dev =
             try
               Some (device_by_id xc xs vm (device_kind_of ~xs vbd) (id_of vbd))
             with
             | (Xenopsd_error (Does_not_exist(_,_))) ->
               debug "VM = %s; VBD = %s; Ignoring missing domain" vm (id_of vbd);
               None
             | Xenopsd_error Device_not_connected ->
               debug "VM = %s; VBD = %s; Ignoring missing device" vm (id_of vbd);
               None in
           let backend = match dev with
             | None -> None
             | Some dv -> match Rpcmarshal.unmarshal typ_of_backend (Device.Generic.get_private_key ~xs dv _vdi_id |> Jsonrpc.of_string) with
               | Ok x -> x
               | Error (`Msg m) -> raise (Xenopsd_error (Internal_error (Printf.sprintf "Failed to unmarshal VBD backend: %s" m)))
           in

           Opt.iter
             (fun dev ->
                if force && (not (Device.can_surprise_remove ~xs dev))
                then debug
                    "VM = %s; VBD = %s; Device is not surprise-removable (ignoring and removing anyway)"
                    vm (id_of vbd); (* this happens on normal shutdown too *)
                (* Case (1): success; Case (2): success; Case (3): an exception is thrown *)
                Xenops_task.with_subtask task (Printf.sprintf "Vbd.clean_shutdown %s" (id_of vbd))
                  (fun () -> (if force then Device.hard_shutdown else Device.clean_shutdown) task ~xs dev);
             ) dev;
           (* We now have a shutdown device but an active DP: we should destroy the DP if the backend is of type VDI *)
           finally
             (fun () ->
                Opt.iter
                  (fun dev ->
                     Xenops_task.with_subtask task (Printf.sprintf "Vbd.release %s" (id_of vbd))
                       (fun () -> Device.Vbd.release task ~xc ~xs dev);
                  ) dev;
                (* If we have a qemu frontend, detach this too. *)
                let _ = DB.update vm (
                    Opt.map (fun vm_t ->
                        let persistent = vm_t.VmExtra.persistent in
                        if List.mem_assoc vbd.Vbd.id persistent.VmExtra.qemu_vbds then begin
                          let _, qemu_vbd = List.assoc vbd.Vbd.id persistent.VmExtra.qemu_vbds in
                          (* destroy_vbd_frontend ignores 'refusing to close' transients' *)
                          destroy_vbd_frontend ~xc ~xs task qemu_vbd;
                          VmExtra.{persistent = { persistent with
                              qemu_vbds = List.remove_assoc vbd.Vbd.id persistent.qemu_vbds }
                          }
                        end else
                          vm_t
                      )
                  )
                in ()
             )
             (fun () ->
                match domid, backend with
                | Some x, None
                | Some x, Some (VDI _)
                  -> Storage.dp_destroy task (Storage.id_of (string_of_int x) vbd.Vbd.id)
                | _ -> ()
             )
         with
         | Device_common.Device_error(_, s) ->
           debug "Caught Device_error: %s" s;
           raise (Xenopsd_error (Device_detach_rejected("VBD", id_of vbd, s)))
      )

  let insert task vm vbd d =
    on_frontend
      (fun xc xs frontend_domid domain_type ->
         if domain_type <> Vm.Domain_HVM
         then plug task vm { vbd with backend = Some d }
         else begin
           let (device: Device_common.device) = device_by_id xc xs vm (device_kind_of ~xs vbd) (id_of vbd) in
           let vdi = attach_and_activate task xc xs frontend_domid vbd (Some d) in
           let params, xenstore_data, _ = params_of_backend vdi.attach_info in
           let phystype = Device.Vbd.Phys in
           (* We store away the disk so we can implement VBD.stat *)
           xs.Xs.write (vdi_path_of_device ~xs device) (d |> rpc_of disk |> Jsonrpc.to_string);
           Device.Vbd.media_insert ~xs ~dm:(dm_of ~vm) ~phystype ~params device;
           Device_common.add_backend_keys ~xs device "sm-data" xenstore_data
         end
      ) vm

  let eject task vm vbd =
    on_frontend
      (fun xc xs frontend_domid _ ->
         let (device: Device_common.device) = device_by_id xc xs vm (device_kind_of ~xs vbd) (id_of vbd) in
         Device.Vbd.media_eject ~xs ~dm:(dm_of ~vm) device;
         safe_rm xs (vdi_path_of_device ~xs device);
         safe_rm xs (Device_common.backend_path_of_device ~xs device ^ "/sm-data");
         Storage.dp_destroy task (Storage.id_of (string_of_int (frontend_domid_of_device device)) vbd.Vbd.id)
      ) vm

  let ionice qos pid =
    try
      run !Xc_resources.ionice (Ionice.set_args qos pid) |> ignore_string
    with e ->
      error "Ionice failed on pid %d: %s" pid (Printexc.to_string e)

  let set_qos task vm vbd =
    with_xc_and_xs
      (fun xc xs ->
         Opt.iter (function
             | Ionice qos ->
               try
                 let (device: Device_common.device) = device_by_id xc xs vm (device_kind_of ~xs vbd) (id_of vbd) in
                 let path = Device_common.kthread_pid_path_of_device ~xs device in
                 let kthread_pid = xs.Xs.read path |> int_of_string in
                 ionice qos kthread_pid
               with
               | Xs_protocol.Enoent _ ->
                 (* This means the kthread-pid hasn't been written yet. We'll be called back later. *)
                 ()
               | e ->
                 error "Failed to ionice kthread-pid: %s" (Printexc.to_string e)
           ) vbd.Vbd.qos
      )

  let get_qos xc xs vm vbd device =
    try
      let path = Device_common.kthread_pid_path_of_device ~xs device in
      let kthread_pid = xs.Xs.read path |> int_of_string in
      let i = run !Xc_resources.ionice (Ionice.get_args kthread_pid) |> Ionice.parse_result_exn in
      Opt.map (fun i -> Ionice i) i
    with
    | Ionice.Parse_failed x ->
      warn "Failed to parse ionice result: %s" x;
      None
    | _ ->
      None

  let string_of_qos = function
    | None -> "None"
    | Some x -> x |> rpc_of Vbd.qos |> Jsonrpc.to_string

  let get_state vm vbd =
    with_xc_and_xs
      (fun xc xs ->
         try
           let (device: Device_common.device) = device_by_id xc xs vm (device_kind_of ~xs vbd) (id_of vbd) in
           let qos_target = get_qos xc xs vm vbd device in

           let backend_present =
             if Device.Vbd.media_is_ejected ~xs device
             then None
             else Some (
               match vdi_path_of_device ~xs device |> xs.Xs.read |> Jsonrpc.of_string |> Rpcmarshal.unmarshal disk.Rpc.Types.ty with
               | Ok d -> d
               | Error (`Msg m) -> raise (Xenopsd_error (Internal_error (Printf.sprintf "Failed to unmarshal disk: %s" m)))) in
           {
             Vbd.active = true;
             plugged = true;
             backend_present;
             qos_target = qos_target
           }
         with
         | (Xenopsd_error (Does_not_exist(_, _)))
         | Xenopsd_error Device_not_connected ->
           { unplugged_vbd with
             Vbd.active = get_active vm vbd
           }
      )

  let get_device_action_request vm vbd =
    with_xc_and_xs
      (fun xc xs ->
         try
           let (device: Device_common.device) = device_by_id xc xs vm (device_kind_of ~xs vbd) (id_of vbd) in
           if Hotplug.device_is_online ~xs device
           then begin
             let qos_target = get_qos xc xs vm vbd device in
             if qos_target <> vbd.Vbd.qos then begin
               debug "VM = %s; VBD = %s; VBD_set_qos needed, current = %s; target = %s" vm (id_of vbd) (string_of_qos qos_target) (string_of_qos vbd.Vbd.qos);
               Some Needs_set_qos
             end else None
           end else begin
             debug "VM = %s; VBD = %s; VBD_unplug needed, device offline: %s" vm (id_of vbd) (Device_common.string_of_device device);
             Some Needs_unplug
           end
         with Xenopsd_error Device_not_connected ->
           debug "VM = %s; VBD = %s; Device_not_connected so no action required" vm (id_of vbd);
           None
      )
end

module VIF = struct
  open Vif

  let id_of vif = snd vif.id

  let backend_domid_of xc xs vif =
    match vif.backend with
    | Network.Local _ | Network.Sriov _ -> this_domid ~xs
    | Network.Remote (vm, _) ->
      begin match vm |> uuid_of_string |> domid_of_uuid ~xc ~xs with
        | None -> raise (Xenopsd_error (Does_not_exist ("domain", vm)))
        | Some x -> x
      end

  let interfaces_of_vif domid id position =
    let mkif name = { Interface.Interface.vif = id; name = Printf.sprintf "%s%d.%d" name domid position; } in
    List.map mkif [ "tap"; "vif" ]

  let _locking_mode = "locking-mode"
  let _ipv4_allowed = "ipv4-allowed"
  let _ipv6_allowed = "ipv6-allowed"
  let _static_ip_setting = "static-ip-setting"

  let locking_mode_keys = [
    _locking_mode;
    _ipv4_allowed;
    _ipv6_allowed;
  ]

  let pvs_proxy_key_prefix = "pvs-"

  let xenstore_of_locking_mode = function
    | Locked { ipv4 = ipv4; ipv6 = ipv6 } -> [
        _locking_mode, "locked";
        _ipv4_allowed, String.concat "," ipv4;
        _ipv6_allowed, String.concat "," ipv6;
      ]
    | Unlocked -> [
        _locking_mode, "unlocked";
      ]
    | Disabled -> [
        _locking_mode, "disabled";
      ]

  let xenstore_of_static_ip_setting vif =
    let constant_setting = [
      "mac", vif.mac;
      "error-code", "0";
      "error-msg", "";
    ] in
    let ipv4_setting = match vif.ipv4_configuration with
      | Unspecified4 -> [ "enabled", "0" ]
      | Static4 (address :: _, gateway) ->
        let enabled = "enabled" , "1" in
        let address = "address", address in
        let gateway = match gateway with Some value -> ["gateway", value] | None -> [] in
        enabled :: address :: gateway
      | Static4 ([], _) -> raise (Xenopsd_error (Internal_error "Static IPv4 configuration selected, but no address specified."))
    in
    let ipv6_setting = match vif.ipv6_configuration with
      | Unspecified6 -> [ "enabled6", "0" ]
      | Static6 (address6 :: _, gateway6) ->
        let enabled6 = "enabled6" , "1" in
        let address6 = "address6", address6 in
        let gateway6 = match gateway6 with Some value -> ["gateway6", value] | None -> [] in
        enabled6 :: address6 :: gateway6
      | Static6 ([], _) -> raise (Xenopsd_error (Internal_error "Static IPv6 configuration selected, but no address specified."))
    in
    let settings = constant_setting @ ipv4_setting @ ipv6_setting in
    List.map (fun (k,v) -> Printf.sprintf "%s/%s" _static_ip_setting k, v) settings

  let disconnect_flag device disconnected =
    let path = Hotplug.vif_disconnect_path device in
    let flag = if disconnected then "1" else "0" in
    path, flag

  let xenstore_of_pvs_proxy proxy =
    match proxy with
    | None -> []
    | Some (s, srvs, iface) ->
      let open Vif.PVS_proxy in
      let server_keys =
        List.mapi (fun i server ->
            let open Printf in
            [
              sprintf "pvs-server-%d-addresses" i, String.concat "," server.addresses;
              sprintf "pvs-server-%d-ports" i, sprintf "%d-%d" server.first_port server.last_port;
            ]
          ) srvs
        |> List.flatten
      in
      ("pvs-site", s) ::
      ("pvs-interface", iface) ::
      ("pvs-server-num", string_of_int (List.length srvs)) ::
      server_keys

  let active_path vm vif = Printf.sprintf "/vm/%s/devices/vif/%s" vm (snd vif.Vif.id)

  let set_active task vm vif active =
    try
      set_active_device (active_path vm vif) active
    with e ->
      debug "set_active %s.%s <- %b failed: %s" (fst vif.Vif.id) (snd vif.Vif.id) active (Printexc.to_string e)

  let get_active vm vif =
    try
      with_xs (fun xs -> xs.Xs.read (active_path vm vif)) = "1"
    with _ -> false

  let device_kind_of vif =
    match vif.backend with
    | Network.Local _ | Network.Remote _ -> Device_common.Vif
    | Network.Sriov _ -> Device_common.NetSriovVf

  let plug_exn task vm vif =
    (* Verify that there is metadata present for the VM *)
    let _ = DB.read_exn vm in
    (* If the vif isn't listed as "active" then we don't automatically plug this one in *)
    if not(get_active vm vif)
    then debug "VIF %s.%s is not active: not plugging into VM" (fst vif.Vif.id) (snd vif.Vif.id)
    else on_frontend
        (fun xc xs frontend_domid _ ->
           let backend_domid = backend_domid_of xc xs vif in
           (* Remember the VIF id with the device *)
           let id = _device_id (device_kind_of vif), id_of vif in
           let xenopsd_backend = [ "xenopsd-backend", "classic" ] in
           let static_ip_setting = xenstore_of_static_ip_setting vif in
           let interfaces = interfaces_of_vif frontend_domid vif.id vif.position in
           let mac = Mac.check_mac vif.mac in
           let with_common_params f =
             f ~xs ~devid:vif.position ~mac ?mtu:(Some vif.mtu) ?rate:(Some vif.rate) 
               ?backend_domid:(Some backend_domid)
               ?other_config:(Some vif.other_config) in
           List.iter (fun interface ->
               Interface.DB.write interface.Interface.Interface.name interface) interfaces;

           Xenops_task.with_subtask task (Printf.sprintf "Vif.add %s" (id_of vif))
             (fun () -> match vif.backend with
                | Network.Local x | Network.Remote (_, x) ->
                  let create =
                    let setup_vif_rules = [ "setup-vif-rules", !Xc_resources.setup_vif_rules ] in
                    let setup_pvs_proxy_rules = [ "setup-pvs-proxy-rules",
                                                  !Xc_resources.setup_pvs_proxy_rules ] in
                    let pvs_proxy = xenstore_of_pvs_proxy vif.pvs_proxy in
                    let locking_mode = xenstore_of_locking_mode vif.locking_mode in
                    (with_common_params Device.Vif.add)
                      ~netty:(Netman.Vswitch x)
                      ~carrier:(vif.carrier && (vif.locking_mode <> Xenops_interface.Vif.Disabled))
                      ~extra_private_keys:(id :: vif.extra_private_keys @ locking_mode @
                                           setup_vif_rules @ setup_pvs_proxy_rules @ pvs_proxy @ xenopsd_backend)
                      ~extra_xenserver_keys:static_ip_setting
                  in
                  let (_: Device_common.device) = create task frontend_domid in

                  (* If qemu is in a different domain, then plug into it *)
                  let me = this_domid ~xs in
                  Opt.iter
                    (fun stubdom_domid ->
                       if vif.position < 4 && stubdom_domid <> me then begin
                         let device = create task stubdom_domid in
                         let q = vif.position, Device device in
                         let _ = DB.update_exn vm (fun vm_t ->
                             Some VmExtra.{persistent = { vm_t.persistent with
                                 qemu_vifs = (vif.Vif.id, q) :: vm_t.persistent.qemu_vifs }
                             }
                           )
                         in ()
                       end
                    ) (get_stubdom ~xs frontend_domid)
                | Network.Sriov pci ->
                  let (_: Device_common.device) =
                    (with_common_params Device.NetSriovVf.add)
                      ~pci ~vlan:vif.vlan ~carrier:vif.carrier
                      ~extra_private_keys:([id] @ xenopsd_backend)
                      ~extra_xenserver_keys:(static_ip_setting @ [("mac", mac)])
                      task frontend_domid
                  in
                  ()
             )
        ) vm

  let plug task vm = plug_exn task vm

  let unplug task vm vif force =
    with_xc_and_xs
      (fun xc xs ->
         try
           (* If the device is gone then this is ok *)
           let device = device_by_id xc xs vm (device_kind_of vif) (id_of vif) in
           begin
             match vif.backend with
             | Network.Local _ | Network.Remote _ ->
               (* If the device is gone then this is ok *)
               let destroy device =
                 (* NB different from the VBD case to make the test pass for now *)
                 Xenops_task.with_subtask task (Printf.sprintf "Vif.hard_shutdown %s" (id_of vif))
                   (fun () -> (if force then Device.hard_shutdown else Device.clean_shutdown) task ~xs device);
                 Xenops_task.with_subtask task (Printf.sprintf "Vif.release %s" (id_of vif))
                   (fun () -> Device.Vif.release task ~xc ~xs device) in
               destroy device;

               DB.update vm (
                 Opt.map (fun vm_t ->
                     (* If we have a qemu frontend, detach this too. *)
                     if List.mem_assoc vif.Vif.id vm_t.VmExtra.persistent.VmExtra.qemu_vifs then begin
                       match (List.assoc vif.Vif.id vm_t.VmExtra.persistent.VmExtra.qemu_vifs) with
                       | _, Device device ->
                         destroy device;
                         VmExtra.{persistent = { vm_t.persistent with
                             qemu_vifs = List.remove_assoc vif.Vif.id vm_t.persistent.qemu_vifs }
                         }
                       | _, _ -> vm_t
                     end else
                       vm_t
                   )
               ) |> ignore
             | Network.Sriov _ ->
               Xenops_task.with_subtask task (Printf.sprintf "NetSriovVf.hard_shutdown %s" (id_of vif))
                 (fun () -> Device.hard_shutdown task ~xs device);
               debug "Unplug on network SR-IOV VF backed VIF = %s. \
                      It would be unplugged until its PCI device is unplugged." (id_of vif)
           end;
           let domid = device.Device_common.frontend.Device_common.domid in
           let interfaces = interfaces_of_vif domid vif.id vif.position in
           List.iter (fun interface ->
               Interface.DB.remove interface.Interface.Interface.name) interfaces
         with
         | (Xenopsd_error (Does_not_exist(_,_))) ->
           debug "VM = %s; Ignoring missing domain" (id_of vif)
         | (Xenopsd_error Device_not_connected) ->
           debug "VM = %s; Ignoring missing device" (id_of vif)
      );
    ()

  let move task vm vif network =
    (* Verify that there is metadata present for the VM *)
    let _ = DB.read_exn vm in
    with_xc_and_xs
      (fun xc xs ->
         try
           (* If the device is gone then this is ok *)
           let device = device_by_id xc xs vm (device_kind_of vif) (id_of vif) in
           let bridge = match network with
             | Network.Local x -> x
             | Network.Sriov _ -> raise (Xenopsd_error (Unimplemented("network SR-IOV")))
             | Network.Remote _ -> raise (Xenopsd_error (Unimplemented("network driver domains"))) in

           Device.Vif.move ~xs device bridge;

           (* If we have a qemu frontend, detach this too. *)
           let _ = DB.update_exn vm (fun vm_t ->
               let persistent = vm_t.VmExtra.persistent in
               if List.mem_assoc vif.Vif.id persistent.VmExtra.qemu_vifs then begin
                 match (List.assoc vif.Vif.id persistent.VmExtra.qemu_vifs) with
                 | _, Device device ->
                   Device.Vif.move ~xs device bridge;
                   Some VmExtra.{persistent = { persistent with
                       qemu_vifs = List.remove_assoc vif.Vif.id persistent.qemu_vifs }
                   }
                 | _, _ -> Some vm_t
               end else
                 Some vm_t
             ) in ()
         with
         | (Xenopsd_error (Does_not_exist(_,_))) ->
           debug "VM = %s; Ignoring missing domain" (id_of vif)
         | (Xenopsd_error Device_not_connected) ->
           debug "VM = %s; Ignoring missing device" (id_of vif)
      );
    ()

  let set_carrier task vm vif carrier =
    with_xc_and_xs
      (fun xc xs ->
         try
           (* If the device is gone then this is ok *)
           let device = device_by_id xc xs vm (device_kind_of vif) (id_of vif) in
           match vif.backend with
           | Network.Local _ | Network.Remote _ -> Device.Vif.set_carrier ~xs device carrier
           | Network.Sriov _ ->
             debug "VIF = %s; Ignoring setting carrier on network SR-IOV backed VIF" (id_of vif)
         with
         | Xenopsd_error (Does_not_exist(_,_)) ->
           debug "VM = %s; Ignoring missing domain" (id_of vif)
         | Xenopsd_error (Device_not_connected) ->
           debug "VM = %s; Ignoring missing device" (id_of vif)
      )

  let set_locking_mode task vm vif mode =
    with_xc_and_xs
      (fun xc xs -> match vif.backend with
         | Network.Sriov _ -> raise (Xenopsd_error (Unimplemented("network SR-IOV")))
         | Network.Local _ | Network.Remote _ ->
           let open Device_common in
           (* If the device is gone then this is ok *)
           let device = device_by_id xc xs vm Vif (id_of vif) in
           let path = Device_common.get_private_data_path_of_device device in
           (* Delete the old keys *)
           List.iter (fun x -> safe_rm xs (path ^ "/" ^ x)) locking_mode_keys;
           List.iter (fun (x, y) -> xs.Xs.write (path ^ "/" ^ x) y) (xenstore_of_locking_mode mode);
           let disconnected = not (vif.carrier && (mode <> Xenops_interface.Vif.Disabled)) in
           let disconnect_path, flag = disconnect_flag device disconnected in
           xs.Xs.write disconnect_path flag;

           let devid = string_of_int device.frontend.devid in
           let vif_interface_name = Printf.sprintf "vif%d.%s" device.frontend.domid devid in
           let tap_interface_name = Printf.sprintf "tap%d.%s" device.frontend.domid devid in
           ignore (run !Xc_resources.setup_vif_rules ["classic"; vif_interface_name; vm; devid; "filter"]);
           (* Update rules for the tap device if the VM has booted HVM with no PV drivers. *)
           let di = Xenctrl.domain_getinfo xc device.frontend.domid in
           if VM.get_domain_type ~xs di = Vm.Domain_HVM
           then ignore (run !Xc_resources.setup_vif_rules ["classic"; tap_interface_name; vm; devid; "filter"])
      )

  let set_ip_unspecified xs xenstore_path suffix =
    Xs.transaction xs (fun t ->
        let ip_setting_enabled = Printf.sprintf "%s/%s%s" xenstore_path "enabled" suffix in
        t.Xst.write ip_setting_enabled "0";

        let ip_setting_address = Printf.sprintf "%s/%s%s" xenstore_path "address" suffix in
        t.Xst.rm ip_setting_address;

        let ip_setting_gateway = Printf.sprintf "%s/%s%s" xenstore_path "gateway" suffix in
        t.Xst.rm ip_setting_gateway
      )

  let set_ip_static xs xenstore_path suffix address gateway =
    Xs.transaction xs (fun t ->
        let ip_setting_enabled = Printf.sprintf "%s/%s%s" xenstore_path "enabled" suffix in
        t.Xst.write ip_setting_enabled "1";

        let ip_setting_address = Printf.sprintf "%s/%s%s" xenstore_path "address" suffix in
        t.Xst.write ip_setting_address address;

        let ip_setting_gateway = Printf.sprintf "%s/%s%s" xenstore_path "gateway" suffix in
        match gateway with
        | None ->
          t.Xst.rm ip_setting_gateway
        | Some value ->
          debug "xenstore-write %s <- %s" ip_setting_gateway value;
          t.Xst.write ip_setting_gateway value
      )

  let set_ipv4_configuration task vm vif ipv4_configuration =
    with_xc_and_xs
      (fun xc xs ->
         let device = device_by_id xc xs vm (device_kind_of vif) (id_of vif) in
         let xenstore_path =
           Printf.sprintf "%s/%s"
             (Device_common.extra_xenserver_path_of_device ~xs device)
             _static_ip_setting
         in
         match ipv4_configuration with
         | Unspecified4 ->
           set_ip_unspecified xs xenstore_path ""
         | Static4 (address :: _, gateway) ->
           set_ip_static xs xenstore_path "" address gateway
         | Static4 ([], _) ->
           raise (Xenopsd_error (Internal_error "Static IPv4 configuration selected, but no address specified."))
      )

  let set_ipv6_configuration task vm vif ipv6_configuration =
    with_xc_and_xs
      (fun xc xs ->
         let device = device_by_id xc xs vm (device_kind_of vif) (id_of vif) in
         let xenstore_path =
           Printf.sprintf "%s/%s"
             (Device_common.extra_xenserver_path_of_device ~xs device)
             _static_ip_setting
         in
         match ipv6_configuration with
         | Unspecified6 ->
           set_ip_unspecified xs xenstore_path "6"
         | Static6 (address :: _, gateway) ->
           set_ip_static xs xenstore_path "6" address gateway
         | Static6 ([], _) ->
           raise (Xenopsd_error (Internal_error "Static IPv6 configuration selected, but no address specified."))
      )

  let set_pvs_proxy task vm vif proxy =
    with_xc_and_xs
      (fun xc xs -> match vif.backend with
         | Network.Sriov _ -> raise (Xenopsd_error (Unimplemented("network SR-IOV")))
         | Network.Local _ | Network.Remote _ ->
           let open Device_common in
           (* If the device is gone then this is ok *)
           let device = device_by_id xc xs vm Vif (id_of vif) in
           let private_path = Device_common.get_private_data_path_of_device device in
           let hotplug_path = Hotplug.get_hotplug_path device in
           let setup action =
             let devid = string_of_int device.frontend.devid in
             let vif_interface_name = Printf.sprintf "vif%d.%s" device.frontend.domid devid in
             let tap_interface_name = Printf.sprintf "tap%d.%s" device.frontend.domid devid in
             let di = Xenctrl.domain_getinfo xc device.frontend.domid in
             ignore (run !Xc_resources.setup_pvs_proxy_rules [action; "vif"; vif_interface_name;
                                                              private_path; hotplug_path]);
             if VM.get_domain_type ~xs di = Vm.Domain_HVM then
               try
                 ignore (run !Xc_resources.setup_pvs_proxy_rules [action; "tap"; tap_interface_name;
                                                                  private_path; hotplug_path])
               with _ ->
                 (* There won't be a tap device if the VM has PV drivers loaded. *)
                 ()
           in
           if proxy = None then begin
             setup "remove";
             Xs.transaction xs (fun t ->
                 let keys = t.Xs.directory private_path in
                 List.iter (fun key ->
                     if String.startswith pvs_proxy_key_prefix key then
                       t.Xs.rm (Printf.sprintf "%s/%s" private_path key)
                   ) keys
               )
           end else begin
             Xs.transaction xs (fun t ->
                 t.Xs.writev private_path (xenstore_of_pvs_proxy proxy)
               );
             setup "add"
           end
      )

  let get_state vm vif =
    with_xc_and_xs
      (fun xc xs -> 
         try
           let (d: Device_common.device) = device_by_id xc xs vm (device_kind_of vif) (id_of vif) in
           let domid = d.Device_common.frontend.Device_common.domid in
           let device = "vif" ^ (string_of_int domid) ^ "." ^ (string_of_int vif.position) in
           match vif.backend with
           | Network.Sriov pci ->
             let pci_state = PCI.get_state' vm pci in
             { unplugged_vif with
               Vif.active = get_active vm vif;
               plugged = Xenops_interface.Pci.(pci_state.plugged);
               device = Some device;
             }
           | Network.Local _ | Network.Remote _ ->
             let path = Device_common.kthread_pid_path_of_device ~xs d in
             let kthread_pid = try xs.Xs.read path |> int_of_string with _ -> 0 in
             let pra_path = Hotplug.vif_pvs_rules_active_path_of_device ~xs d in
             let pvs_rules_active = try (ignore (xs.Xs.read pra_path); true) with _ -> false in
             (* We say the device is present unless it has been deleted
                from xenstore. The corrolary is that: only when the device
                is finally deleted from xenstore, can we remove bridges or
                switch configuration. *)
             {
               Vif.active = true;
               plugged = true;
               media_present = true;
               kthread_pid = kthread_pid;
               device = Some device;
               pvs_rules_active = pvs_rules_active;
             }
         with
         | (Xenopsd_error (Does_not_exist(_,_)))
         | Xenopsd_error Device_not_connected ->
           { unplugged_vif with
             Vif.active = get_active vm vif
           }
      )

  let get_device_action_request vm vif =
    with_xc_and_xs
      (fun xc xs -> match vif.backend with
         | Network.Sriov _ -> None
         | Network.Local _ | Network.Remote _ ->
           try
             let (device: Device_common.device) = device_by_id xc xs vm (device_kind_of vif) (id_of vif) in
             if Hotplug.device_is_online ~xs device
             then None
             else Some Needs_unplug
           with Xenopsd_error Device_not_connected ->
             None
      )

end

module UPDATES = struct
  let get last timeout = Updates.get "UPDATES.get" last timeout internal_updates
end

module IntMap = Map.Make(struct type t = int let compare = compare end)

module Actions = struct
  (* CA-76600: the rtc/timeoffset needs to be maintained over a migrate. *)
  let store_rtc_timeoffset vm timeoffset =
    let _ = DB.update vm (
        Opt.map (function { VmExtra.persistent } as extra ->
          match persistent with
          | { VmExtra.ty = Some ( Vm.HVM hvm_info ) } ->
            let persistent = { persistent with VmExtra.ty = Some (Vm.HVM { hvm_info with Vm.timeoffset = timeoffset }) } in
            debug "VM = %s; rtc/timeoffset <- %s" vm timeoffset;
            VmExtra.{persistent}
          | _ -> extra
          )
      )
    in ()

  let maybe_update_pv_drivers_detected ~xc ~xs domid path =
    let vm = get_uuid ~xc domid |> Uuidm.to_string in
    Opt.iter
      (function { VmExtra.persistent } ->
         if not persistent.VmExtra.pv_drivers_detected then begin
           (* If the new value for this device is 4 then PV drivers are present *)
           try
             let value = xs.Xs.read path in
             if value = "4" (* connected *) then begin
               let updated =
                 DB.update vm (
                   Opt.map (function { VmExtra.persistent } ->
                       let persistent = { persistent with VmExtra.pv_drivers_detected = true } in
                       debug "VM = %s; found PV driver evidence on %s (value = %s)" vm path value;
                       VmExtra.{persistent}
                     )
                 )
               in
               if updated then
                 Updates.add (Dynamic.Vm vm) internal_updates
             end
           with Xs_protocol.Enoent _ ->
             warn "Watch event on %s fired but couldn't read from it" path;
             () (* the path must have disappeared immediately after the watch fired. Let's treat this as if we never saw it. *)
         end
      ) (DB.read vm)

  let interesting_paths_for_domain domid uuid =
    let open Printf in [
      sprintf "/local/domain/%d/attr" domid;
      sprintf "/local/domain/%d/data/updated" domid;
      sprintf "/local/domain/%d/data/ts" domid;
      sprintf "/local/domain/%d/memory/target" domid;
      sprintf "/local/domain/%d/memory/uncooperative" domid;
      sprintf "/local/domain/%d/console/vnc-port" domid;
      sprintf "/local/domain/%d/console/tc-port" domid;
      Device.Qemu.pid_path_signal domid;
      sprintf "/local/domain/%d/control" domid;
      sprintf "/local/domain/%d/device" domid;
      sprintf "/local/domain/%d/rrd" domid;
      sprintf "/local/domain/%d/vm-data" domid;
      sprintf "/local/domain/%d/feature" domid;
      sprintf "/vm/%s/rtc/timeoffset" uuid;
      sprintf "/local/domain/%d/xenserver/attr" domid;
    ]

  let watch_token domid = Printf.sprintf "xenopsd-xc:domain-%d" domid

  let watches_of_device dev =
    let interesting_backend_keys = [
      "kthread-pid";
      "tapdisk-pid";
      "shutdown-done";
      "hotplug-status";
      "params";
      "state";
    ] in
    let open Device_common in
    let be = dev.backend.domid in
    let fe = dev.frontend.domid in
    let kind = string_of_kind dev.backend.kind in
    let devid = dev.frontend.devid in
    List.map (fun k -> Printf.sprintf "/local/domain/%d/backend/%s/%d/%d/%s" be kind fe devid k) interesting_backend_keys

  let unmanaged_domain domid id =
    domid > 0 && not (DB.exists id)

  let found_running_domain domid id =
    Updates.add (Dynamic.Vm id) internal_updates

  let device_watches = ref IntMap.empty

  let domain_appeared xc xs domid =
    device_watches := IntMap.add domid [] !device_watches

  let domain_disappeared xc xs domid =
    let token = watch_token domid in
    List.iter (fun d ->
        List.iter (Xenstore_watch.unwatch ~xs token) (watches_of_device d)
      ) (try IntMap.find domid !device_watches with Not_found -> []);
    device_watches := IntMap.remove domid !device_watches;

    (* Anyone blocked on a domain/device operation which won't happen because the domain
       just shutdown should be cancelled here. *)
    debug "Cancelling watches for: domid %d" domid;
    Cancel_utils.on_shutdown ~xs domid;
    (* Finally, discard any device caching for the domid destroyed *)
    DeviceCache.discard device_cache domid

  let qemu_disappeared di xc xs =
    match !Xenopsd.action_after_qemu_crash with
    | None -> ()
    | Some action -> begin
        debug "action-after-qemu-crash=%s" action;
        match action with
        | "poweroff" ->
          (* we do not expect a HVM guest to survive qemu disappearing, so kill the VM *)
          Domain.set_action_request ~xs di.Xenctrl.domid (Some "poweroff")
        | "pause" ->
          (* useful for debugging qemu *)
          Domain.pause ~xc di.Xenctrl.domid
        | _ -> ()
      end

  let add_device_watch xs watch_cb device =
    let open Device_common in
    debug "Adding watches for: %s" (string_of_device dev);
    let domid = dev.frontend.domid in
    let token = watch_token domid in
    List.iter (Xenstore_watch.watch ~xs token watch_cb) (watches_of_device device);
    device_watches := IntMap.add domid (device :: (IntMap.find domid !device_watches)) !device_watches

  let remove_device_watch xs dev =
    let open Device_common in
    debug "Removing watches for: %s" (string_of_device dev);
    let domid = dev.frontend.domid in
    let current = IntMap.find domid !device_watches in
    let token = watch_token domid in
    List.iter (Xenstore_watch.unwatch ~xs token) (watches_of_device dev);
    device_watches := IntMap.add domid (List.filter (fun x -> x <> dev) current) !device_watches

  let watch_fired xc xs path domains watches watch_cb =
    debug "In Actions.watch_fired: path=%s" path;
    let look_for_different_devices domid =
      if not(Xenstore_watch.IntSet.mem domid watches)
      then debug "Ignoring frontend device watch on unmanaged domain: %d" domid
      else if not(IntMap.mem domid !device_watches)
      then warn "Xenstore watch fired, but no entry for domid %d in device watches list" domid
      else begin
        let devices = IntMap.find domid !device_watches in
        let devices' = Device_common.list_frontends ~xs domid in
        let old_devices = Stdext.Listext.List.set_difference devices devices' in
        let new_devices = Stdext.Listext.List.set_difference devices' devices in
        List.iter (add_device_watch xs watch_cb) new_devices;
        List.iter (remove_device_watch xs) old_devices;
      end in

    let fire_event_on_vm domid =
      let d = int_of_string domid in
      let open Xenstore_watch in
      if not(IntMap.mem d domains)
      then debug "Ignoring watch on shutdown domain %d" d
      else
        let di = IntMap.find d domains in
        let open Xenctrl in
        let id = Uuidm.to_string (uuid_of_di di) in
        Updates.add (Dynamic.Vm id) internal_updates in

    let fire_event_on_device domid kind devid =
      let d = int_of_string domid in
      let open Xenstore_watch in
      if not(IntMap.mem d domains)
      then debug "Ignoring watch on shutdown domain %d" d
      else
        let di = IntMap.find d domains in
        let open Xenctrl in
        let id = Uuidm.to_string (uuid_of_di di) in
        let update = match kind with
          | "vbd" | "vbd3" | "qdisk" ->
            let devid' = devid |> int_of_string |> Device_number.of_xenstore_key |> Device_number.to_linux_device in
            Some (Dynamic.Vbd (id, devid'))
          | "vif" -> Some (Dynamic.Vif (id, devid))
          | x ->
            debug "Unknown device kind: '%s'" x;
            None in
        Opt.iter (fun x -> Updates.add x internal_updates) update in

    let fire_event_on_qemu domid =
      let d = int_of_string domid in
      let open Xenstore_watch in
      if not(IntMap.mem d domains)
      then debug "Ignoring qemu-pid-signal watch on shutdown domain %d" d
      else begin
        let signal = try Some (xs.Xs.read (Device.Qemu.pid_path_signal d)) with _ -> None in
        match signal with
        | None -> ()
        | Some signal ->
          debug "Received unexpected qemu-pid-signal %s for domid %d" signal d;
          let di = IntMap.find d domains in
          let id = Uuidm.to_string (uuid_of_di di) in
          qemu_disappeared di xc xs;
          Updates.add (Dynamic.Vm id) internal_updates
      end
    in

    let register_rrd_plugin ~domid ~name ~grant_refs ~protocol =
      debug
        "Registering RRD plugin: frontend_domid = %d, name = %s, refs = [%s]"
        domid name
        (List.map string_of_int grant_refs |> String.concat ";");
      let uid =
        { Rrd_interface.name = name
        ; frontend_domid = domid
        } in
      let info =
        { Rrd_interface.frequency = Rrd.Five_Seconds
        ; shared_page_refs = grant_refs
        } in
      let (_: float) =
        RRDD.Plugin.Interdomain.register uid info protocol
      in ()
    in

    let deregister_rrd_plugin ~domid ~name =
      debug
        "Deregistering RRD plugin: frontend_domid = %d, name = %s"
        domid name;
      let uid = {Rrd_interface.name = name; frontend_domid = domid} in
      RRDD.Plugin.Interdomain.deregister uid
    in

    match List.filter (fun x -> x <> "") (Stdext.Xstringext.String.split '/' path) with
    | "local" :: "domain" :: domid :: "backend" :: kind :: frontend :: devid :: key ->
      debug "Watch on backend domid: %s kind: %s -> frontend domid: %s devid: %s" domid kind frontend devid;
      fire_event_on_device frontend kind devid;
      (* If this event was a state change then this might be the first time we see evidence of PV drivers *)
      if key = ["state"] then maybe_update_pv_drivers_detected ~xc ~xs (int_of_string frontend) path
    | "local" :: "domain" :: frontend :: "device" :: _ ->
      look_for_different_devices (int_of_string frontend)
    | "local" :: "domain" :: domid :: "rrd" :: name :: "ready" :: [] -> begin
        debug "Watch picked up an RRD plugin: domid = %s, name = %s" domid name;
        try
          let grant_refs_path =
            Printf.sprintf "/local/domain/%s/rrd/%s/grantrefs" domid name
          in
          let protocol_path =
            Printf.sprintf "/local/domain/%s/rrd/%s/protocol" domid name
          in
          let grant_refs = xs.Xs.read grant_refs_path
                           |> Stdext.Xstringext.String.split ','
                           |> List.map int_of_string
          in
          let protocol =
            xs.Xs.read protocol_path
            |> Rrd_interface.protocol_of_string in
          register_rrd_plugin
            ~domid:(int_of_string domid) ~name ~grant_refs ~protocol
        with e ->
          debug
            "Failed to register RRD plugin: caught %s"
            (Printexc.to_string e)
      end
    | "local" :: "domain" :: domid :: "rrd" :: name :: "shutdown" :: [] ->
      let value =
        try Some (xs.Xs.read path)
        with Xs_protocol.Enoent _ -> None
      in
      if value = Some "true" then begin
        debug
          "RRD plugin has announced shutdown: domid = %s, name = %s"
          domid name;
        safe_rm xs (Printf.sprintf "local/domain/%s/rrd/%s" domid name);
        try deregister_rrd_plugin ~domid:(int_of_string domid) ~name
        with e ->
          debug
            "Failed to deregister RRD plugin: caught %s"
            (Printexc.to_string e)
      end
    | "local" :: "domain" :: domid :: "qemu-pid-signal" :: [] ->
      fire_event_on_qemu domid
    | "local" :: "domain" :: domid :: _ ->
      fire_event_on_vm domid
    | "vm" :: uuid :: "rtc" :: "timeoffset" :: [] ->
      let timeoffset = try Some (xs.Xs.read path) with _ -> None in
      Opt.iter
        (fun timeoffset ->
           (* Store the rtc/timeoffset for migrate *)
           store_rtc_timeoffset uuid timeoffset;
           (* Tell the higher-level toolstack about this too *)
           Updates.add (Dynamic.Vm uuid) internal_updates
        ) timeoffset
    | _  -> debug "Ignoring unexpected watch: %s" path
end

module Watcher = Xenstore_watch.WatchXenstore(Actions)

(* Here we analyse common startup errors in more detail and
   suggest the most likely fixes (e.g. switch to root, start missing
   service) *)

let look_for_forkexec () =
  try
    let _ = run "/bin/ls" [] in
    debug "fork/exec service is responding"
  with e ->
    error "The fork/exec service is not working properly. The raw error was: %s" (Printexc.to_string e);
    error "This is a fatal error because I will not be able to start any VMs.";
    error "Please start (or restart) the fork/exec service and try again.";
    exit 1

let look_for_xen () = match detect_hypervisor () with
  | Some (Xen (major, minor)) -> major, minor
  | Some (Other x) ->
    error "You are running a different hypervisor (%s)" x;
    error "Please check your bootloader configuration, reboot to xen and try again.";
    exit 1
  | None ->
    error "The file %s does not exist: you are not running xen." _sys_hypervisor_type;
    error "Please check your bootloader configuration, reboot to xen and try again.";
    exit 1

let look_for_xenctrl () =
  try
    let xc = Xenctrl.interface_open () in
    debug "xenctrl interface is available";
    Xenctrl.interface_close xc;
  with e ->
    error "I failed to open the low-level xen control interface (xenctrl)";
    error "The raw error was: %s" (Printexc.to_string e);
    if Unix.geteuid () = 0 then begin
      debug "You are running as root -- this is good.";
      error "Please check you have a matching hypervisor, xenctrl libraries and xenopsd.";
      error "If the problem persists then contact: <xen-api@lists.xen.org>";
      exit 1;
    end else begin
      error "You are not running as root.";
      error "Please switch to root and try again.";
      exit 1;
    end

let init () =
  look_for_forkexec ();

  let major, minor = look_for_xen () in

  look_for_xenctrl ();

  if major < "4" || (major = "4" && minor < "2") && !Xenopsd.run_hotplug_scripts then begin
    error "This is xen version %s.%s. On all versions < 4.1 we must use hotplug/udev scripts" major minor;
    error "To fix this error either upgrade xen or set run_hotplug_scripts=false in xenopsd.conf";
    error "Setting run_hotplug_scripts to false so we can continue: this may cause device timeouts.";
    Xenopsd.run_hotplug_scripts := false
  end;

  if !Xenopsd.run_hotplug_scripts then begin
    with_xs
      (fun xs ->
         xs.Xs.write disable_udev_path "1";
         info "Written %s to disable the hotplug/udev scripts" disable_udev_path;
      )
  end;
  (* XXX: is this completely redundant now? The Citrix PV drivers don't need this any more *)
  (* Special XS entry looked for by the XenSource PV drivers (see xenagentd.hg:src/xad.c) *)
  let xe_key = "/mh/XenSource-TM_XenEnterprise-TM" in
  let xe_val = "XenSource(TM) and XenEnterprise(TM) are registered trademarks of XenSource Inc." in

  with_xs
    (fun xs ->
       xs.Xs.write xe_key xe_val;
       xs.Xs.setperms xe_key { Xs_protocol.ACL.owner = 0; other = Xs_protocol.ACL.READ; acl = [] }
    );

  Device.Backend.init();
  debug "xenstore is responding to requests";
  let () = Watcher.create_watcher_thread () in
  ()

module DEBUG = struct
  let trigger cmd args = match cmd, args with
    | "reboot", [ k ] ->
      let uuid = uuid_of_string k in
      with_xc_and_xs
        (fun xc xs ->
           match di_of_uuid ~xc ~xs uuid with
           | None -> raise (Xenopsd_error (Does_not_exist("domain", k)))
           | Some di ->
             Xenctrl.domain_shutdown xc di.Xenctrl.domid Xenctrl.Reboot
        )
    | _ ->
      debug "DEBUG.trigger cmd=%s Unimplemented" cmd;
      raise (Xenopsd_error (Unimplemented(cmd)))
end
