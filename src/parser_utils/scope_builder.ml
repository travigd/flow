(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Flow_ast_visitor
open Hoister
open Scope_api

module LocMap = Utils_js.LocMap

class with_or_eval_visitor = object(this)
  inherit [bool] visitor ~init:false as super

  method! expression (expr: Loc.t Ast.Expression.t) =
    let open Ast.Expression in
    if this#acc = true then expr else match expr with
    | (_, Call { Call.callee = (_, Identifier (_, "eval")); _}) ->
      this#set_acc true;
      expr
    | _ -> super#expression expr

  method! statement (stmt: Loc.t Ast.Statement.t) =
    if this#acc = true then stmt else super#statement stmt

  method! with_ (stuff: Loc.t Ast.Statement.With.t) =
    this#set_acc true;
    stuff
end

(* Visitor class that prepares use-def info, hoisting bindings one scope at a
   time. This info can be used for various purposes, e.g. variable renaming.

   We do not generate the scope tree for the entire program, because it is not
   clear where to hang scopes for function expressions, catch clauses,
   etc. One possibility is to augment the AST with scope identifiers.

   As we move into a nested scope, we generate bindings for the new scope, map
   the bindings to names generated by a factory, and augment the existing
   environment with this map before visiting the nested scope.
*)
module Acc = struct
  type t = info
  let init = {
    max_distinct = 0;
    scopes = IMap.empty;
  }
end

module Env : sig
  type t
  val empty: t
  val mk_env: (unit -> int) -> t -> Bindings.t -> t
  val get: string -> t -> Def.t option
  val defs: t -> Def.t SMap.t
end = struct
  type t = Def.t SMap.t list
  let empty = []

  let rec get x t =
    match t with
    | [] -> None
    | hd::rest ->
      begin match SMap.get x hd with
      | Some def -> Some def
      | None -> get x rest
      end

  let defs = function
    | [] -> SMap.empty
    | hd::_ -> hd

  let mk_env next parent_env bindings =
    let bindings = Bindings.to_assoc bindings in
    let env = List.fold_left (fun env (x, locs) ->
      let name = match get x parent_env with
        | Some def -> def.Def.name
        | None -> next () in
      SMap.add x { Def.locs; name; actual_name=x } env
    ) SMap.empty bindings in
    env::parent_env
end

class scope_builder = object(this)
  inherit [Acc.t] visitor ~init:Acc.init as super

  val mutable env = Env.empty
  val mutable current_scope_opt = None
  val mutable scope_counter = 0
  val mutable uses = []

  method private new_scope =
    let new_scope = scope_counter in
    scope_counter <- scope_counter + 1;
    new_scope

  val mutable counter = 0
  method private next =
    let result = counter in
    counter <- counter + 1;
    this#update_acc (fun acc -> { acc with
      max_distinct = max counter acc.max_distinct
    });
    result

  method with_bindings: 'a. ?lexical:bool -> Bindings.t -> ('a -> 'a) -> 'a -> 'a =
    fun ?(lexical=false) bindings visit node ->
      let save_counter = counter in
      let save_uses = uses in
      let old_env = env in
      let parent = current_scope_opt in
      let child = this#new_scope in
      uses <- [];
      current_scope_opt <- Some child;
      env <- Env.mk_env (fun () -> this#next) old_env bindings;
      let node' = visit node in
      this#update_acc (fun acc ->
        let defs = Env.defs env in
        let locals = SMap.fold (fun _ def locals ->
          List.fold_left (fun locals loc -> LocMap.add loc def locals) locals def.Def.locs
        ) defs LocMap.empty in
        let locals, globals = List.fold_left (fun (locals, globals) (loc, x) ->
          match Env.get x env with
          | Some def -> LocMap.add loc def locals, globals
          | None -> locals, SSet.add x globals
        ) (locals, SSet.empty) uses in
        let scopes = IMap.add child { Scope.lexical; parent; defs; locals; globals; } acc.scopes in
        { acc with scopes }
      );
      uses <- save_uses;
      current_scope_opt <- parent;
      env <- old_env;
      counter <- save_counter;
      node'

  method! identifier (expr: Loc.t Ast.Identifier.t) =
    uses <- expr::uses;
    expr

  (* don't rename the `foo` in `x.foo` *)
  method! member_property_identifier (id: Loc.t Ast.Identifier.t) = id

  (* don't rename the `foo` in `{ foo: ... }` *)
  method! object_key_identifier (id: Loc.t Ast.Identifier.t) = id

  method! block (stmt: Loc.t Ast.Statement.Block.t) =
    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = lexical_hoist#eval lexical_hoist#block stmt in
    this#with_bindings ~lexical:true lexical_bindings super#block stmt

  (* like block *)
  method! program (program: Loc.t Ast.program) =
    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = lexical_hoist#eval lexical_hoist#program program in
    this#with_bindings ~lexical:true lexical_bindings super#program program

  method private scoped_for_in_statement (stmt: Loc.t Ast.Statement.ForIn.t) =
    super#for_in_statement stmt

  method! for_in_statement (stmt: Loc.t Ast.Statement.ForIn.t) =
    let open Ast.Statement.ForIn in
    let { left; right = _; body = _; each = _ } = stmt in

    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = match left with
    | LeftDeclaration (_, decl) ->
      lexical_hoist#eval lexical_hoist#variable_declaration decl
    | LeftPattern _ -> Bindings.empty
    in
    this#with_bindings ~lexical:true lexical_bindings this#scoped_for_in_statement stmt

  method private scoped_for_of_statement (stmt: Loc.t Ast.Statement.ForOf.t) =
    super#for_of_statement stmt

  method! for_of_statement (stmt: Loc.t Ast.Statement.ForOf.t) =
    let open Ast.Statement.ForOf in
    let { left; right = _; body = _; async = _ } = stmt in

    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = match left with
    | LeftDeclaration (_, decl) ->
      lexical_hoist#eval lexical_hoist#variable_declaration decl
    | LeftPattern _ -> Bindings.empty
    in
    this#with_bindings ~lexical:true lexical_bindings this#scoped_for_of_statement stmt

  method private scoped_for_statement (stmt: Loc.t Ast.Statement.For.t) =
    super#for_statement stmt

  method! for_statement (stmt: Loc.t Ast.Statement.For.t) =
    let open Ast.Statement.For in
    let { init; test = _; update = _; body = _ } = stmt in

    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = match init with
    | Some (InitDeclaration (_, decl)) ->
      lexical_hoist#eval lexical_hoist#variable_declaration decl
    | _ -> Bindings.empty
    in
    this#with_bindings ~lexical:true lexical_bindings this#scoped_for_statement stmt

  method! catch_clause (clause: Loc.t Ast.Statement.Try.CatchClause.t') =
    let open Ast.Statement.Try.CatchClause in
    let { param; body = _ } = clause in

    this#with_bindings (
      let open Ast.Pattern in
      let _, patt = param in
      match patt with
      | Identifier { Identifier.name; _ } -> Bindings.singleton name
      | _ -> (* TODO *)
        Bindings.empty
    ) super#catch_clause clause

  (* helper for function params and body *)
  method private lambda params body =
    let open Ast.Function in

    (* hoisting *)
    let hoist = new hoister in
    begin
      let (_loc, { Params.params = param_list; rest = _rest }) = params in
      run_list hoist#function_param_pattern param_list;
      match body with
        | BodyBlock (_loc, block) ->
          run hoist#block block
        | _ ->
          ()
    end;

    this#with_bindings hoist#acc (fun () ->
      let (_loc, { Params.params = param_list; rest }) = params in
      run_list this#function_param_pattern param_list;
      run_opt this#function_rest_element rest;
      begin match body with
      | BodyBlock (_, block) ->
        run this#block block
      | BodyExpression expr ->
        run this#expression expr
      end;
    ) ()

  method! function_declaration (expr: Loc.t Ast.Function.t) =
    let contains_with_or_eval =
      let visit = new with_or_eval_visitor in
      visit#eval visit#function_declaration expr
    in

    if not contains_with_or_eval then begin
      let open Ast.Function in
      let {
        id; params; body; async = _; generator = _; expression = _;
        predicate = _; returnType = _; typeParameters = _;
      } = expr in

      run_opt this#function_identifier id;

      this#lambda params body;
    end;

    expr

  (* Almost the same as function_declaration, except that the name of the
     function expression is locally in scope. *)
  method! function_ (expr: Loc.t Ast.Function.t) =
    let contains_with_or_eval =
      let visit = new with_or_eval_visitor in
      visit#eval visit#function_ expr
    in

    if not contains_with_or_eval then begin
      let open Ast.Function in
      let {
        id; params; body; async = _; generator = _; expression = _;
        predicate = _; returnType = _; typeParameters = _;
      } = expr in

      let bindings = match id with
        | Some name -> Bindings.singleton name
        | None -> Bindings.empty in
      this#with_bindings bindings (fun () ->
        run_opt this#function_identifier id;
        this#lambda params body;
      ) ();
    end;

    expr
end

let program ?(ignore_toplevel=false) program =
  let walk = new scope_builder in
  if ignore_toplevel then walk#eval walk#program program
  else
    let hoist = new hoister in
    let bindings = hoist#eval hoist#program program in
    walk#eval (walk#with_bindings bindings walk#program) program
