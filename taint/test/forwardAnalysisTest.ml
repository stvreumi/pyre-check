(** Copyright (c) 2018-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Analysis
open Ast
open Pyre
open Statement
open Taint
open Domains

open Test
open Interprocedural


type source_expectation = {
  define_name: string;
  returns: Sources.t list;
}


let assert_taint ?(qualifier = Access.create "qualifier") source expect =
  let source =
    parse ~qualifier source
    |> Preprocessing.preprocess
  in
  let configuration = Test.mock_configuration in
  let environment = Test.environment ~configuration () in
  Service.Environment.populate environment [source];
  TypeCheck.check configuration environment source |> ignore;
  let defines =
    source
    |> Preprocessing.defines
    |> List.rev
  in
  let () =
    List.map ~f:Callable.create defines
    |> Fixpoint.KeySet.of_list
    |> Fixpoint.remove_new
  in
  let analyze_and_store_in_order define =
    let call_target = Callable.create define in
    let () =
      Log.log
        ~section:`Taint
        "Analyzing %s"
        (Interprocedural.Callable.show call_target)
    in
    let forward, _errors = ForwardAnalysis.run ~environment ~define in
    let model = { Taint.Result.empty_model with forward } in
    Result.empty_model
    |> Result.with_model Taint.Result.kind model
    |> Fixpoint.add_predefined call_target;
  in
  let () = List.iter ~f:analyze_and_store_in_order defines in
  let check_expectation { define_name; returns } =
    let open Taint.Result in
    let expected_call_target = Callable.create_real (Access.create define_name) in
    let model =
      Fixpoint.get_model expected_call_target
      >>= Result.get_model Taint.Result.kind
    in
    match model with
    | None -> assert_failure ("no model for " ^ define_name)
    | Some { forward = { source_taint; } ; _ } ->
        let returned_sources =
          ForwardState.read AccessPath.Root.LocalResult source_taint
          |> ForwardState.collapse
          |> ForwardTaint.leaves
          |> List.map ~f:Sources.show
          |> String.Set.of_list
        in
        let expected_sources =
          List.map ~f:Sources.show returns
          |> String.Set.of_list
        in
        assert_equal
          ~cmp:String.Set.equal
          ~printer:(fun set -> Sexp.to_string [%message (set: String.Set.t)])
          expected_sources
          returned_sources
  in
  List.iter ~f:check_expectation expect



let test_no_model _ =
  let assert_no_model _ =
    assert_taint
      ?qualifier:None
      {|
      def copy_source():
        pass
      |}
      [
        {
          define_name = "does_not_exist";
          returns = [];
        };
      ]
  in
  assert_raises
    (OUnitTest.OUnit_failure "no model for does_not_exist")
    assert_no_model


let test_simple_source _ =
  assert_taint
    {|
      def simple_source():
        return __testSource()
    |}
    [
      {
        define_name = "qualifier.simple_source";
        returns = [Sources.TestSource];
      };
    ]


let test_local_copy _ =
  assert_taint
    {|
      def copy_source():
        var = __testSource()
        return var
    |}
    [
      {
        define_name = "qualifier.copy_source";
        returns = [Sources.TestSource];
      };
    ]


let test_class_model _ =
  assert_taint
    {|
      class Foo:
        def bar():
          return __testSource()
    |}
    [
      {
        define_name = "qualifier.Foo.bar";
        returns = [Sources.TestSource];
      };
    ]


let test_apply_method_model_at_call_site _ =
  assert_taint
    {|
      class Foo:
        def qux():
          return __testSource()

      class Bar:
        def qux():
          return not_tainted()

      def taint_across_methods():
        f = Foo()
        return f.qux()
    |}
    [
      {
        define_name = "qualifier.taint_across_methods";
        returns = [Sources.TestSource];
      };
    ];

  assert_taint
    {|
      class Foo:
        def qux():
          return __testSource()

      class Bar:
        def qux():
          return not_tainted()

      def taint_across_methods():
        f = Bar()
        return f.qux()
    |}
    [
      {
        define_name = "qualifier.taint_across_methods";
        returns = [];
      };
    ];

  assert_taint
    {|
      class Foo:
        def qux():
          return __testSource()

      class Bar:
        def qux():
          return not_tainted()

      def taint_across_methods(f: Foo):
        return f.qux()
    |}
    [
      {
        define_name = "qualifier.taint_across_methods";
        returns = [Sources.TestSource];
      }
    ];

  assert_taint
    {|
      class Foo:
        def qux():
          return __testSource()

      class Bar:
        def qux():
          return not_tainted()

      def taint_across_methods(f: Bar):
        return f.qux()
    |}
    [
      {
        define_name = "qualifier.taint_across_methods";
        returns = [];
      };
    ];

  assert_taint
    {|
      class Foo:
        def qux():
          return __testSource()

      class Bar:
        def qux():
          return not_tainted()

      def taint_with_union_type(condition):
        if condition:
          f = Foo()
        else:
          f = Bar()

        return f.qux()
    |}
    [
      {
        define_name = "qualifier.taint_with_union_type";
        returns = [Sources.TestSource];
      };
    ];

  assert_taint
    {|
      class Foo:
        def qux():
          return not_tainted()

      class Bar:
        def qux():
          return not_tainted()

      class Baz:
        def qux():
          return __testSource()

      def taint_with_union_type(condition):
        if condition:
          f = Foo()
        elif condition > 1:
          f = Bar()
        else:
          f = Baz()

        return f.qux()
    |}
    [
      {
        define_name = "qualifier.taint_with_union_type";
        returns = [Sources.TestSource];
      };
    ];

  assert_taint
    {|
      class Indirect:
        def direct(self) -> Direct: ...

      class Direct:
        def source():
          return __testSource()

      def taint_indirect_concatenated_call(indirect: Indirect):
        direct = indirect.direct()
        return direct.source()
    |}
    [
      {
        define_name = "qualifier.taint_indirect_concatenated_call";
        returns = [Sources.TestSource];
      }
    ];
  assert_taint
    {|
      class Indirect:
        def direct(self) -> Direct: ...

      class Direct:
        def source():
          return __testSource()

      def taint_indirect_concatenated_call(indirect: Indirect):
        return indirect.direct().source()
    |}
    [
      {
        define_name = "qualifier.taint_indirect_concatenated_call";
        returns = [Sources.TestSource];
      }
    ]


let test_taint_in_taint_out_application _ =
  assert_taint
    {|
      def simple_source():
        return __testSource()

      def taint_with_tito():
        y = simple_source()
        x = __tito(y)
        return x
    |}
    [
      {
        define_name = "qualifier.simple_source";
        returns = [Sources.TestSource];
      };
    ];

  assert_taint
    {|
      def simple_source():
        return __testSource()

      def no_tito_taint():
        y = simple_source()
        x = __no_tito(y)
        return x
    |}
    [
      {
        define_name = "qualifier.no_tito_taint";
        returns = [];
      };
    ]


let () =
  "taint">:::[
    "no_model">::test_no_model;
    "simple">::test_simple_source;
    "copy">::test_local_copy;
    "class_model">::test_class_model;
    "test_apply_method_model_at_call_site">::test_apply_method_model_at_call_site;
    "test_taint_in_taint_out_application">::test_taint_in_taint_out_application;
    "test_union">::test_taint_in_taint_out_application;
  ]
  |> Test.run_with_taint_models
