(* supermin 5
 * Copyright (C) 2009-2014 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 *)

open Unix
open Printf

open Utils
open Ext2fs
open Ext2init
open Fnmatch

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

let string_set_of_list strs = List.fold_right StringSet.add strs StringSet.empty
let keys map = StringMap.fold (fun k _ ks -> k :: ks) map []

(* The list of modules (wildcards) we consider for inclusion in the
 * mini initrd.  Only what is needed in order to find a device with an
 * ext2 filesystem on it.
 *)
let kmods = [
  "ext2.ko*";
  "ext4.ko*";    (* CONFIG_EXT4_USE_FOR_EXT23=y option might be set *)
  "virtio*.ko*";
  "ide*.ko*";
  "libata*.ko*";
  "piix*.ko*";
  "scsi_transport_spi.ko*";
  "scsi_mod.ko*";
  "sd_mod.ko*";
  "sym53c8xx.ko*";
  "ata_piix.ko*";
  "sr_mod.ko*";
  "mbcache.ko*";
  "crc*.ko*";
  "libcrc*.ko*";
  "ibmvscsic.ko*";
  "megaraid*.ko*";
]

let rec build_initrd debug tmpdir modpath initrd =
  if debug >= 1 then
    printf "supermin: ext2: creating minimal initrd '%s'\n%!" initrd;

  let initdir = tmpdir // "init.d" in
  mkdir initdir 0o755;

  (* Read modules.dep file. *)
  let moddeps = read_module_deps modpath in

  (* Create a set of top-level modules, that is any module which
   * matches a pattern in kmods.
   *)
  let topset =
    let mods = keys moddeps in
    List.fold_left (
      fun topset modl ->
        let m = Filename.basename modl in
        let matches wildcard = fnmatch wildcard m [FNM_PATHNAME] in
        if List.exists matches kmods then
          StringSet.add modl topset
        else
          topset
    ) StringSet.empty mods in

  (* Do depth-first search to locate the modules we need to load.  Keep
   * track of which modules we've added so we don't add them twice.
   *)
  let visited = Hashtbl.create 13 in
  let loaded = ref 0 in
  let chan = open_out (initdir // "modules") in
  let rec visit set =
    StringSet.iter (
      fun modl ->
        if not (Hashtbl.mem visited modl) then (
          Hashtbl.add visited modl true;

          if debug >= 2 then
            printf "supermin: ext2: initrd: visiting module %s\n%!" modl;

          (* Visit dependencies first. *)
          let deps =
            try StringMap.find modl moddeps
            with Not_found -> StringSet.empty in
          visit deps;

          (* Copy module to the init directory. *)
          let cmd =
            sprintf "cp -t %s %s" (quote initdir) (quote (modpath // modl)) in
          run_command cmd;

          (* Write module name to 'modules' file. *)
          fprintf chan "%s\n" (Filename.basename modl);
          incr loaded
        )
    ) set
  in
  visit topset;
  close_out chan;

  if debug >= 1 then
    printf "supermin: ext2: wrote %d modules to minimal initrd\n%!" !loaded;

  (* This is the binary blob containing the init "script". *)
  let init = binary_init () in
  let initfile = initdir // "init" in
  let chan = open_out initfile in
  output_string chan init;
  close_out chan;
  chmod initfile 0o755;

  (* Build the cpio file. *)
  let cmd =
    sprintf "(cd %s && (echo .; ls -1) | cpio --quiet -o -H newc) > %s"
      (quote initdir) (quote initrd) in
  run_command cmd

(* Read modules.dep into internal structure. *)
and read_module_deps modpath =
  let modules_dep = modpath // "modules.dep" in
  let chan = open_in modules_dep in
  let lines = input_all_lines chan in
  close_in chan;
  List.fold_left (
    fun map line ->
      let i = String.index line ':' in
      let modl = String.sub line 0 i in
      let deps = String.sub line (i+1) (String.length line - (i+1)) in
      let deps =
        if deps <> "" && deps <> " " then (
          let deps =
            let len = String.length deps in
            if len >= 1 && deps.[0] = ' ' then String.sub deps 1 (len-1)
            else deps in
          let deps = string_split " " deps in
          string_set_of_list deps
        )
        else StringSet.empty in
      StringMap.add modl deps map
  ) StringMap.empty lines
