%%% @doc cowboy-swagger main interface.
-module(cowboy_swagger).

%% API
-export([to_json/1, add_definition/2, add_definition_array/2, schema/1]).

%% Utilities
-export([enc_json/1, dec_json/1]).
-export([swagger_paths/1, validate_metadata/1]).
-export([filter_cowboy_swagger_handler/1]).
-export([get_existing_definitions/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Types.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-opaque parameter_obj() ::
  #{ name        => iodata()
   , in          => iodata()
   , description => iodata()
   , required    => boolean()
   , type        => iodata()
   , schema      => iodata()
   }.
-export_type([parameter_obj/0]).

-opaque response_obj() ::
  #{ description => binary()
   }.
-type responses_definitions() :: #{binary() => response_obj()}.
-export_type([response_obj/0, responses_definitions/0]).

-type parameter_definition_name () :: binary().
-type property_desc() ::
  #{ type => binary()
   , description => binary()
   , example => binary()
   , items => property_desc()
   }.
-type property_obj() :: #{binary() => property_desc()}.
-type parameters_definitions() ::
  #{parameter_definition_name() =>
      #{ type => binary()
       , properties => property_obj()
       }}.
-type parameters_definition_array() ::
  #{parameter_definition_name() =>
      #{ type => binary()
       , items => #{ type => binary()
                   , properties => property_obj()
                   }
       }}.
-export_type([ parameter_definition_name/0
             , property_obj/0
             , parameters_definitions/0
             , parameters_definition_array/0
             ]).

%% Swagger map spec
-opaque swagger_map() ::
  #{ description => iodata()
   , summary     => iodata()
   , parameters  => [parameter_obj()]
   , tags        => [iodata()]
   , consumes    => [iodata()]
   , produces    => [iodata()]
   , responses   => responses_definitions()
   }.
-type metadata() :: trails:metadata(swagger_map()).
-export_type([swagger_map/0, metadata/0]).

-type swagger_version() :: swagger_2_0
                         | openapi_3_0_0.
-export_type([swagger_version/0]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Returns the swagger json specification from given `trails'.
%%      This function basically takes the metadata from each `trails:trail()'
%%      (which must be compliant with Swagger specification) and builds the
%%      required `swagger.json'.
-spec to_json([trails:trail()]) -> jsx:json_text().
to_json(Trails) ->
  Default = #{info => #{title => <<"API-DOCS">>}},
  GlobalSpec = normalize_map_values(
    application:get_env(cowboy_swagger, global_spec, Default)),
  SanitizeTrails = filter_cowboy_swagger_handler(Trails),
  SwaggerSpec = create_swagger_spec(GlobalSpec, SanitizeTrails),
  enc_json(SwaggerSpec).

-spec add_definition_array( Name::parameter_definition_name()
                          , Properties::property_obj()
                          ) ->
  ok.
add_definition_array(Name, Properties) ->
  DefinitionArray = build_definition_array(Name, Properties),
  add_definition(DefinitionArray).

-spec add_definition( Name::parameter_definition_name()
                    , Properties::property_obj()
                    ) ->
  ok.
add_definition(Name, Properties) ->
  Definition = build_definition(Name, Properties),
  add_definition(Definition).

-spec add_definition( Definition :: parameters_definitions()
                                  | parameters_definition_array()
                    ) ->
  ok.
add_definition(Definition) ->
  CurrentSpec = application:get_env(cowboy_swagger, global_spec, #{}),
  NewDefinitions = maps:merge( get_existing_definitions(CurrentSpec)
                             , Definition
                             ),
  NewSpec = prepare_new_global_spec(CurrentSpec, NewDefinitions),
  application:set_env(cowboy_swagger, global_spec, NewSpec).

-spec schema(DefinitionName::parameter_definition_name()) ->
  map().
schema(DefinitionName) ->
  case swagger_version() of
    swagger_2_0 ->
      #{<<"$ref">> => <<"#/definitions/", DefinitionName/binary>>};
    openapi_3_0_0 ->
      #{<<"$ref">> => <<"#/components/schemas/", DefinitionName/binary>>}
  end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Utilities.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @hidden
-spec enc_json(jsx:json_term()) -> jsx:json_text().
enc_json(Json) ->
  jsx:encode(Json, [uescape]).

%% @hidden
-spec dec_json(iodata()) -> jsx:json_term().
dec_json(Data) ->
  try jsx:decode(Data, [return_maps])
  catch
    _:{error, _} ->
      throw(bad_json)
  end.

%% @hidden
-spec swagger_paths([trails:trail()]) -> map().
swagger_paths(Trails) ->
  swagger_paths(Trails, #{}).

%% @hidden
-spec validate_metadata(trails:metadata(_)) -> metadata().
validate_metadata(Metadata) ->
  validate_swagger_map(Metadata).

%% @hidden
-spec filter_cowboy_swagger_handler([trails:trail()]) -> [trails:trail()].
filter_cowboy_swagger_handler(Trails) ->
  F = fun(Trail) ->
    MD = trails:metadata(Trail),
    maps:size(maps:filter(fun is_visible/2, MD)) /= 0
  end,
  lists:filter(F, Trails).

-spec get_existing_definitions(CurrentSpec :: map()) ->
  Definition :: parameters_definitions()
              | parameters_definition_array().
get_existing_definitions(CurrentSpec) ->
  case swagger_version() of
    swagger_2_0 ->
      maps:get(definitions, CurrentSpec, #{});
    openapi_3_0_0 ->
      case CurrentSpec of
        #{components :=
            #{schemas := Schemas }} -> Schemas;
        _Other                      -> #{}
      end
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Private API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @private
-spec swagger_version() -> swagger_version().
swagger_version() ->
  case application:get_env(cowboy_swagger, global_spec, #{}) of
    #{openapi := "3.0.0"} -> openapi_3_0_0;
    #{swagger := "2.0"}   -> swagger_2_0;
    _Other                -> swagger_2_0
  end.

%% @private
is_visible(_Method, Metadata) ->
  not maps:get(hidden, Metadata, false).

%% @private
swagger_paths([], Acc) ->
  Acc;
swagger_paths([Trail | T], Acc) ->
  Path = normalize_path(trails:path_match(Trail)),
  Metadata = normalize_map_values(validate_metadata(trails:metadata(Trail))),
  swagger_paths(T, maps:put(Path, Metadata, Acc)).

%% @private
normalize_path(Path) ->
  re:replace(
    re:replace(Path, "\\:\\w+", "\\{&\\}", [global]),
    "\\[|\\]|\\:", "", [{return, binary}, global]).

%% @private
normalize_map_values(Map) when is_map(Map) ->
  normalize_map_values(maps:to_list(Map));
normalize_map_values(Proplist) ->
  F = fun({K, []}, Acc) ->
        maps:put(K, normalize_list_values([]), Acc);
      ({K, V}, Acc) when is_list(V) ->
        case io_lib:printable_list(V) of
          true  -> maps:put(K, list_to_binary(V), Acc);
          false -> maps:put(K, normalize_list_values(V), Acc)
        end;
      ({K, V}, Acc) when is_map(V) ->
        maps:put(K, normalize_map_values(V), Acc);
      ({K, V}, Acc) ->
        maps:put(K, V, Acc)
      end,
  lists:foldl(F, #{}, Proplist).

%% @private
normalize_list_values(List) ->
  F = fun(V, Acc) when is_list(V) ->
          case io_lib:printable_list(V) of
            true  -> [list_to_binary(V) | Acc];
            false -> [normalize_list_values(V) | Acc]
          end;
      (V, Acc) when is_map(V) ->
        [normalize_map_values(V) | Acc];
      (V, Acc) ->
        [V | Acc]
      end,
  lists:foldr(F, [], List).

%% @private
create_swagger_spec(#{openapi := _Version} = GlobalSpec, SanitizeTrails) ->
  GlobalSpec#{paths => swagger_paths(SanitizeTrails)};
create_swagger_spec(GlobalSpec, SanitizeTrails) ->
  create_swagger_spec(GlobalSpec#{openapi => <<"3.0.0">>}, SanitizeTrails).

%% @private
validate_swagger_map(Map) ->
  F = fun(_K, V) ->
        Params = validate_swagger_map_params(maps:get(parameters, V, [])),
        Responses = validate_swagger_map_responses(maps:get(responses, V, #{})),
        V#{parameters => Params, responses => Responses}
      end,
  maps:map(F, Map).

%% @private
validate_swagger_map_params(Params) ->
  ValidateParams =
    fun(E) ->
      case maps:get(name, E, undefined) of
        undefined -> false;
        _         -> {true, E#{in => maps:get(in, E, <<"path">>)}}
      end
    end,
  lists:filtermap(ValidateParams, Params).

%% @private
validate_swagger_map_responses(Responses) ->
  F = fun(_K, V) -> V#{description => maps:get(description, V, <<"">>)} end,
  maps:map(F, Responses).

%% @private
-spec build_definition( Name::parameter_definition_name()
                      , Properties::property_obj()
                      ) ->
  parameters_definitions().
build_definition(Name, Properties) ->
  #{Name => #{ type => <<"object">>
             , properties => Properties
             }}.

%% @private
-spec build_definition_array( Name::parameter_definition_name()
                            , Properties::property_obj()
                            ) ->
  parameters_definition_array().
build_definition_array(Name, Properties) ->
  #{Name => #{ type => <<"array">>
             , items => #{ type => <<"object">>
                         , properties => Properties
                         }
             }}.

%% @private
-spec prepare_new_global_spec( CurrentSpec :: map()
                             , Definitions :: parameters_definitions()
                                            | parameters_definition_array()
                             ) ->
  NewSpec :: map().
prepare_new_global_spec(CurrentSpec, Definitions) ->
  case swagger_version() of
    swagger_2_0 ->
      CurrentSpec#{definitions => Definitions
                  };
    openapi_3_0_0 ->
      CurrentSpec#{components =>
                    #{ schemas => Definitions
                     }
                  }
  end.