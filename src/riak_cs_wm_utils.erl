%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_cs_wm_utils).

-export([service_available/2,
         service_available/3,
         parse_auth_header/2,
         iso_8601_datetime/0,
         to_iso_8601/1,
         iso_8601_to_rfc_1123/1,
         to_rfc_1123/1,
         streaming_get/4,
         user_record_to_json/1,
         user_record_to_xml/1,
         find_and_auth_user/3,
         find_and_auth_user/4,
         find_and_auth_user/5,
         validate_auth_header/4,
         ensure_doc/2,
         deny_access/2,
         deny_invalid_key/2,
         extract_name/1,
         normalize_headers/1,
         extract_amazon_headers/1,
         extract_user_metadata/1,
         shift_to_owner/4,
         bucket_access_authorize_helper/4,
         object_access_authorize_helper/4
        ]).

-include("riak_cs.hrl").
-include_lib("webmachine/include/webmachine.hrl").

-define(QS_KEYID, "AWSAccessKeyId").
-define(QS_SIGNATURE, "Signature").

%% ===================================================================
%% Public API
%% ===================================================================

service_available(RD, Ctx) ->
    case riak_cs_utils:riak_connection() of
        {ok, Pid} ->
            {true, RD, Ctx#context{riakc_pid=Pid}};
        {error, _Reason} ->
            {false, RD, Ctx}
    end.

service_available(Pool, RD, Ctx) ->
    case riak_cs_utils:riak_connection(Pool) of
        {ok, Pid} ->
            {true, RD, Ctx#context{riakc_pid=Pid}};
        {error, _Reason} ->
            {false, RD, Ctx}
    end.

%% @doc Parse an authentication header string and determine
%%      the appropriate module to use to authenticate the request.
%%      The passthru auth can be used either with a KeyID or
%%      anonymously by leving the header empty.
-spec parse_auth_header(string(), boolean()) -> {atom(),
                                                 string() | undefined,
                                                 string() | undefined}.
parse_auth_header(KeyId, true) when KeyId =/= undefined ->
    {riak_cs_passthru_auth, KeyId, undefined};
parse_auth_header(_, true) ->
    {riak_cs_passthru_auth, [], undefined};
parse_auth_header(undefined, false) ->
    {riak_cs_blockall_auth, undefined, undefined};
parse_auth_header("AWS " ++ Key, _) ->
    case string:tokens(Key, ":") of
        [KeyId, KeyData] ->
            {riak_cs_s3_auth, KeyId, KeyData};
        Other -> Other
    end;
parse_auth_header(_, _) ->
    {riak_cs_blockall_auth, undefined, undefined}.

%% @doc Parse authentication query parameters and determine
%%      the appropriate module to use to authenticate the request.
%%      The passthru auth can be used either with a KeyID or
%%      anonymously by leving the header empty.
-spec parse_auth_params(string(), string(), boolean()) -> {atom(),
                                                           string() | undefined,
                                                           string() | undefined}.
parse_auth_params(KeyId, _, true) when KeyId =/= undefined ->
    {riak_cs_passthru_auth, KeyId, undefined};
parse_auth_params(_, _, true) ->
    {riak_cs_passthru_auth, [], undefined};
parse_auth_params(undefined, _, false) ->
    {riak_cs_blockall_auth, undefined, undefined};
parse_auth_params(_, undefined, _) ->
    {riak_cs_blockall_auth, undefined, undefined};
parse_auth_params(KeyId, Signature, _) ->
    {riak_cs_s3_auth, KeyId, Signature}.

%% @doc Lookup the user specified by the access headers, and call
%% `Next(RD, NewCtx)' if there is no auth error.
%%
%% If a user was successfully authed, the `user' and `user_object'
%% fields in the `#context' record passed to `Next' will be filled.
%% If the access is instead anonymous, those fields will be left as
%% they were passed to this function.
%%
%% If authorization fails (a bad key or signature is given, or the
%% Riak lookup fails), a tuple suitable for returning from a
%% webmachine resource's `forbidden/2' function is returned, with
%% appropriate error message included.
find_and_auth_user(RD, ICtx, Next) ->
    find_and_auth_user(RD, ICtx, Next, true).

find_and_auth_user(RD, ICtx, Next, AnonymousOk) ->
    find_and_auth_user(RD, ICtx, Next, fun(X) -> X end, AnonymousOk).

find_and_auth_user(RD,
                   #context{auth_bypass=AuthBypass,
                            riakc_pid=RiakPid}=ICtx,
                   Next,
                   Conv2KeyCtx,
                   AnonymousOk) ->
    handle_validation_response(
      validate_auth_header(RD, AuthBypass, RiakPid, ICtx),
      RD,
      ICtx,
      Next,
      Conv2KeyCtx,
      AnonymousOk).

handle_validation_response({ok, User, UserObj}, RD, Ctx, Next, _, _) ->
    %% given keyid and signature matched, proceed
    Next(RD, Ctx#context{user=User,
                         user_object=UserObj});
handle_validation_response({error, no_user_key}, RD, Ctx, Next, _, true) ->
    %% no keyid was given, proceed anonymously
    lager:debug("No user key"),
    Next(RD, Ctx);
handle_validation_response({error, no_user_key}, RD, Ctx, _, Conv2KeyCtx, false) ->
    %% no keyid was given, deny access
    lager:debug("No user key, deny"),
    deny_access(RD, Conv2KeyCtx(Ctx));
handle_validation_response({error, bad_auth}, RD, Ctx, _, Conv2KeyCtx, _) ->
    %% given keyid was found, but signature didn't match
    lager:info("bad_auth"),
    deny_access(RD, Conv2KeyCtx(Ctx));
handle_validation_response({error, _Reason}, RD, Ctx, _, Conv2KeyCtx, _) ->
    %% no matching keyid was found, or lookup failed
    lager:info("other"),
    deny_invalid_key(RD, Conv2KeyCtx(Ctx)).

%% @doc Look for an Authorization header in the request, and validate
%% it if it exists.  Returns `{ok, User, UserObj}' if validation
%% succeeds, or `{error, KeyId, Reason}' if any step fails.
-spec validate_auth_header(#wm_reqdata{}, term(), pid(), #context{}) ->
                                  {ok, rcs_user(), riakc_obj:riakc_obj()} |
                                  {error, bad_auth | notfound | no_user_key | term()}.
validate_auth_header(RD, AuthBypass, RiakPid, Ctx) ->
    AuthHeader = wrq:get_req_header("authorization", RD),
    case AuthHeader of
        undefined ->
            %% Check for auth info presented as query params
            KeyId = wrq:get_qs_value(?QS_KEYID, RD),
            EncodedSig = wrq:get_qs_value(?QS_SIGNATURE, RD),
            {AuthMod, KeyId, Signature} = parse_auth_params(KeyId,
                                                            EncodedSig,
                                                            AuthBypass);
        _ ->
            {AuthMod, KeyId, Signature} = parse_auth_header(AuthHeader, AuthBypass)
    end,
    case riak_cs_utils:get_user(KeyId, RiakPid) of
        {ok, {User, UserObj}} when User?RCS_USER.status =:= enabled ->
            case AuthMod:authenticate(User, Signature, RD, Ctx) of
                ok ->
                    {ok, User, UserObj};
                {error, _Reason} ->
                    %% TODO: are the errors here of small enough
                    %% number that we could just handle them in
                    %% forbidden/2?
                    {error, bad_auth}
            end;
        {ok, _} ->
            %% Disabled account so return 403
            {error, bad_auth};
        {error, NE} when NE == notfound; NE == no_user_key ->
            %% anonymous access lookups don't need to be logged, and
            %% auth failures are logged by other means
            {error, NE};
        {error, Reason} ->
            %% other failures, like Riak fetch timeout, be loud about
            _ = lager:error("Retrieval of user record for ~p failed. Reason: ~p",
                            [KeyId, Reason]),
            {error, Reason}
    end.

%% @doc Utility function for accessing
%%      a riakc_obj without retrieving
%%      it again if it's already in the
%%      Ctx
-spec ensure_doc(term(), pid()) -> term().
ensure_doc(KeyCtx=#key_context{get_fsm_pid=undefined,
                               bucket=Bucket,
                               key=Key}, RiakcPid) ->
    %% start the get_fsm
    BinKey = list_to_binary(Key),
    {ok, Pid} = riak_cs_get_fsm_sup:start_get_fsm(node(), Bucket, BinKey, self(), RiakcPid),
    Manifest = riak_cs_get_fsm:get_manifest(Pid),
    KeyCtx#key_context{get_fsm_pid=Pid, manifest=Manifest};
ensure_doc(KeyCtx, _) ->
    KeyCtx.

%% @doc Produce an access-denied error message from a webmachine
%% resource's `forbidden/2' function.
deny_access(RD, Ctx) ->
    riak_cs_s3_response:api_error(access_denied, RD, Ctx).

%% @doc Prodice an invalid-access-keyid error message from a
%% webmachine resource's `forbidden/2' function.
deny_invalid_key(RD, Ctx) ->
    riak_cs_s3_response:api_error(invalid_access_key_id, RD, Ctx).

%% @doc In the case is a user is authorized to perform an operation on
%% a bucket but is not the owner of that bucket this function can be used
%% to switch to the owner's record if it can be retrieved
-spec shift_to_owner(#wm_reqdata{}, #context{}, string(), pid()) ->
                            {boolean(), #wm_reqdata{}, #context{}}.
shift_to_owner(RD, Ctx=#context{}, OwnerId, RiakPid) when RiakPid /= undefined ->
    case riak_cs_utils:get_user(OwnerId, RiakPid) of
        {ok, {Owner, OwnerObject}} when Owner?RCS_USER.status =:= enabled ->
            AccessRD = riak_cs_access_logger:set_user(Owner, RD),
            {false, AccessRD, Ctx#context{user=Owner,
                                          user_object=OwnerObject}};
        {ok, _} ->
            riak_cs_wm_utils:deny_access(RD, Ctx);
        {error, _} ->
            riak_cs_s3_response:api_error(bucket_owner_unavailable, RD, Ctx)
    end.

streaming_get(FsmPid, StartTime, UserName, BFile_str) ->
    case riak_cs_get_fsm:get_next_chunk(FsmPid) of
        {done, Chunk} ->
            ok = riak_cs_stats:update_with_start(object_get, StartTime),
            riak_cs_dtrace:dt_object_return(riak_cs_wm_object, <<"object_get">>,
                                               [], [UserName, BFile_str]),
            {Chunk, done};
        {chunk, Chunk} ->
            {Chunk, fun() -> streaming_get(FsmPid, StartTime, UserName, BFile_str) end}
    end.

%% @doc Convert a Riak CS user record to JSON
-spec user_record_to_json(term()) -> {struct, [{atom(), term()}]}.
user_record_to_json(?RCS_USER{email=Email,
                              display_name=DisplayName,
                              name=Name,
                              key_id=KeyID,
                              key_secret=KeySecret,
                              canonical_id=CanonicalID,
                              status=Status}) ->
    case Status of
        enabled ->
            StatusBin = <<"enabled">>;
        _ ->
            StatusBin = <<"disabled">>
    end,
    UserData = [{email, list_to_binary(Email)},
                {display_name, list_to_binary(DisplayName)},
                {name, list_to_binary(Name)},
                {key_id, list_to_binary(KeyID)},
                {key_secret, list_to_binary(KeySecret)},
                {id, list_to_binary(CanonicalID)},
                {status, StatusBin}],
    {struct, UserData}.

%% @doc Convert a Riak CS user record to XML
-spec user_record_to_xml(term()) -> {atom(), [{atom(), term()}]}.
user_record_to_xml(?RCS_USER{email=Email,
                              display_name=DisplayName,
                              name=Name,
                              key_id=KeyID,
                              key_secret=KeySecret,
                              canonical_id=CanonicalID,
                              status=Status}) ->
    case Status of
        enabled ->
            StatusStr = "enabled";
        _ ->
            StatusStr = "disabled"
    end,
    {'User',
      [
       {'Email', [Email]},
       {'DisplayName', [DisplayName]},
       {'Name', [Name]},
       {'KeyId', [KeyID]},
       {'KeySecret', [KeySecret]},
       {'Id', [CanonicalID]},
       {'Status', [StatusStr]}
      ]}.

%% @doc Get an ISO 8601 formatted timestamp representing
%% current time.
-spec iso_8601_datetime() -> string().
iso_8601_datetime() ->
    {{Year, Month, Day}, {Hour, Min, Sec}} = erlang:universaltime(),
    iso_8601_format(Year, Month, Day, Hour, Min, Sec).

%% @doc Convert an RFC 1123 date into an ISO 8601 formatted timestamp.
-spec to_iso_8601(string()) -> string().
to_iso_8601(Date) ->
    case httpd_util:convert_request_date(Date) of
        {{Year, Month, Day}, {Hour, Min, Sec}} ->
            iso_8601_format(Year, Month, Day, Hour, Min, Sec);
        bad_date ->
            %% Date is already in ISO 8601 format
            Date
    end.

-spec to_rfc_1123(string()) -> string().
to_rfc_1123(Date) when is_list(Date) ->
    case httpd_util:convert_request_date(Date) of
        {{_Year, _Month, _Day}, {_Hour, _Min, _Sec}} ->
            %% Date is already in RFC 1123 format
            Date;
        bad_date ->
            iso_8601_to_rfc_1123(Date)
    end.

%% @doc Convert an ISO 8601 date to RFC 1123 date. This function
%% assumes the input time is already in GMT time.
-spec iso_8601_to_rfc_1123(binary() | string()) -> string().
iso_8601_to_rfc_1123(Date) when is_list(Date) ->
    iso_8601_to_rfc_1123(iolist_to_binary(Date));
iso_8601_to_rfc_1123(Date) when is_binary(Date) ->
    %% e.g. "2012-02-17T18:22:50.000Z"
    <<Yr:4/binary, _:1/binary, Mo:2/binary, _:1/binary, Da:2/binary,
      _T:1/binary,
      Hr:2/binary, _:1/binary, Mn:2/binary, _:1/binary, Sc:2/binary,
      _/binary>> = Date,
    httpd_util:rfc1123_date(
      erlang:universaltime_to_localtime({{b2i(Yr), b2i(Mo), b2i(Da)},
                                         {b2i(Hr), b2i(Mn), b2i(Sc)}})).

extract_name(User) when is_list(User) ->
    User;
extract_name(?RCS_USER{name=Name}) ->
    Name;
extract_name(_) ->
    "-unknown-".

extract_amazon_headers(Headers) ->
    FilterFun =
        fun({K, V}, Acc) ->
                case lists:prefix("x-amz-", K) of
                    true ->
                        V2 = unicode:characters_to_binary(V, utf8),
                        [[K, ":", V2, "\n"] | Acc];
                    false ->
                        Acc
                end
        end,
    ordsets:from_list(lists:foldl(FilterFun, [], Headers)).

%% @doc Extract user metadata ("x-amz-meta") from request header
%% copied from riak_cs_s3_auth.erl
extract_user_metadata(RD) ->
    extract_metadata(normalize_headers(RD)).

get_request_headers(RD) ->
    mochiweb_headers:to_list(wrq:req_headers(RD)).

normalize_headers(RD) ->
    Headers = get_request_headers(RD),
    FilterFun =
        fun({K, V}, Acc) ->
                LowerKey = string:to_lower(any_to_list(K)),
                [{LowerKey, V} | Acc]
        end,
    ordsets:from_list(lists:foldl(FilterFun, [], Headers)).

extract_metadata(Headers) ->
    FilterFun =
        fun({K, V}, Acc) ->
                case lists:prefix("x-amz-meta-", K) of
                    true ->
                        V2 = unicode:characters_to_list(V, utf8),
                        [{K, V2} | Acc];
                    false ->
                        Acc
                end
        end,
    ordsets:from_list(lists:foldl(FilterFun, [], Headers)).

-spec bucket_access_authorize_helper(AccessType::atom(), boolean(),
                                     RD::term(), Ctx::term()) -> term().
bucket_access_authorize_helper(AccessType, Deletable,
                               RD, #context{user=User,
                                            policy_module=PolicyMod,
                                            riakc_pid=RiakPid}=Ctx)
  when ( AccessType =:= bucket_acl orelse
         AccessType =:= bucket_policy orelse
         AccessType =:= bucket_location orelse
         AccessType =:= bucket_version orelse
         AccessType =:= bucket )
       andalso is_boolean(Deletable) ->

    Method = wrq:method(RD),
    RequestedAccess =
        case AccessType of
            bucket_acl -> riak_cs_acl_utils:requested_access(Method, true);
            _ ->      riak_cs_acl_utils:requested_access(Method, false)
        end,

    Bucket = list_to_binary(wrq:path_info(bucket, RD)),
    PermCtx = Ctx#context{bucket=Bucket,
                          requested_perm=RequestedAccess},

    case riak_cs_utils:get_bucket_acl_policy(Bucket, RiakPid) of
        {error, notfound} ->
            riak_cs_s3_response:api_error(no_such_bucket, RD, Ctx);

        {error, Reason} when is_atom(Reason) ->
            riak_cs_s3_response:api_error(Reason, RD, Ctx);

        {ok, {BucketAcl, Policy}} ->

            case riak_cs_acl_utils:check_grants(User,Bucket,RequestedAccess,RiakPid,BucketAcl) of
                true ->
                    %% because users are not allowed to create/destroy
                    %% buckets, we can assume that User is not
                    %% undefined here
                    AccessRD = riak_cs_access_logger:set_user(User, RD),
                    Access = PolicyMod:reqdata_to_access(RD, AccessType,
                                                         User?RCS_USER.canonical_id),
                    case PolicyMod:eval(Access, Policy) of
                        true ->      {false, AccessRD, PermCtx};
                        undefined -> {false, AccessRD, PermCtx};
                        false ->     riak_cs_wm_utils:deny_access(AccessRD, Ctx)
                    end;

                {true, _OwnerId} when Deletable andalso (RequestedAccess == 'WRITE') ->
                    %% grants lied: this is a delete, and only the
                    %% owner is allowed to do that; setting user for
                    %% the request anyway, so the error tally is
                    %% logged for them
                    AccessRD = riak_cs_access_logger:set_user(User, RD),
                    riak_cs_wm_utils:deny_access(AccessRD, PermCtx);

                {true, OwnerId} ->
                    %% this operation is allowed, but we need to get
                    %% the owner's record, and log the access against
                    %% them instead of the actor
                    riak_cs_wm_utils:shift_to_owner(RD, PermCtx, OwnerId, RiakPid);

                false ->
                    Access = PolicyMod:reqdata_to_access(RD, AccessType,
                                                         User?RCS_USER.canonical_id),
                    PolicyResult = PolicyMod:eval(Access, Policy),

                    case {User, PolicyResult} of
                        {_, true} ->
                            OwnerId = riak_cs_acl:owner_id(BucketAcl, RiakPid),
                            %% Policy says yes while ACL says no
                            riak_cs_wm_utils:shift_to_owner(RD, PermCtx, OwnerId, RiakPid);

                        {undefined, _} ->
                            %% no facility for logging bad access
                            %% against unknown actors
                            AccessRD = RD,
                            riak_cs_wm_utils:deny_access(AccessRD, PermCtx);
                        {_, _} ->
                            %% log bad requests against the actors
                            %% that make them
                            AccessRD = riak_cs_access_logger:set_user(User, RD),
                            %% Check if the bucket actually exists so we can
                            %% make the correct decision to return a 404 or 403
                            case riak_cs_utils:check_bucket_exists(Bucket, RiakPid) of
                                {ok, _} ->
                                    riak_cs_wm_utils:deny_access(AccessRD, PermCtx);
                                {error, Reason} ->
                                    riak_cs_s3_response:api_error(Reason, RD, Ctx)
                            end
                    end
            end
    end.

-spec object_access_authorize_helper(AccessType::atom(), boolean(),
                                     RD::term(), Ctx::term()) -> term().
object_access_authorize_helper(AccessType, Deletable,
                               RD, #context{user=User,
                                            policy_module=PolicyMod,
                                            local_context=LocalCtx,
                                            riakc_pid=RiakPid}=Ctx)
  when ( AccessType =:= object_acl orelse
         AccessType =:= object )
       andalso is_boolean(Deletable) ->

    Method = wrq:method(RD),
    #key_context{bucket=Bucket, manifest=Mfst} = LocalCtx,

    CanonicalId = case Ctx#context.user of
                      undefined ->  undefined;
                      User ->       User?RCS_USER.canonical_id
                  end,
    RequestedAccess =
        case AccessType of
            object ->
                riak_cs_acl_utils:requested_access(Method, false);
            object_acl ->
                riak_cs_acl_utils:requested_access(Method, true)
        end,

    ObjectAcl = case Mfst of
                    notfound -> undefined;
                    _ ->        Mfst?MANIFEST.acl
                end,

    {ok, {_BucketAcl, Policy}} = riak_cs_utils:get_bucket_acl_policy(Bucket, RiakPid),
    Access = PolicyMod:reqdata_to_access(RD, AccessType, CanonicalId),

    case {riak_cs_acl:object_access(Bucket,
                                   ObjectAcl,
                                   RequestedAccess,
                                   CanonicalId,
                                   RiakPid),
          PolicyMod:eval(Access, Policy)} of

        {true, false} when Method =:= 'PUT' orelse
                           (Deletable andalso Method =:= 'DELETE') ->
            %% actor is the owner
            AccessRD = riak_cs_access_logger:set_user(User, RD),

            riak_cs_wm_utils:deny_access(AccessRD, Ctx);
        {true, false} when Method =:= 'GET' orelse
                           (Deletable andalso Method =:= 'HEAD') ->
            {{halt, 404}, riak_cs_access_logger:set_user(Ctx#context.user, RD), Ctx};

        {true, _} ->
            %% actor is the owner
            AccessRD = riak_cs_access_logger:set_user(User, RD),
            UserStr = User?RCS_USER.canonical_id,
            UpdLocalCtx = LocalCtx#key_context{owner=UserStr},
            {false, AccessRD, Ctx#context{local_context=UpdLocalCtx}};

        {{true, OwnerId}, false} when Method =:= 'PUT' orelse
                                      (Deletable andalso Method =:= 'DELETE') ->
            %% actor is not the owner
            AccessRD = riak_cs_access_logger:set_user(OwnerId, RD),
            riak_cs_wm_utils:deny_access(AccessRD, Ctx);

        {{true, _OwnerId}, false} when Method =:= 'GET' orelse
                                       (Deletable andalso Method =:= 'HEAD') ->
            {{halt, 404}, RD, Ctx};

        {{true, OwnerId}, _} ->
            %% actor is not the owner
            AccessRD = riak_cs_access_logger:set_user(OwnerId, RD),
            UpdLocalCtx = LocalCtx#key_context{owner=OwnerId},
            {false, AccessRD, Ctx#context{local_context=UpdLocalCtx}};

        {false, true} ->
            %% actor is not the owner, not permitted by ACL but permitted by policy
            OwnerId = riak_cs_acl:owner_id(ObjectAcl, RiakPid),
            AccessRD = riak_cs_access_logger:set_user(OwnerId, RD),
            UpdLocalCtx = LocalCtx#key_context{owner=OwnerId},
            {false, AccessRD, Ctx#context{local_context=UpdLocalCtx}};

        {false, _} -> % policy says undefined or false
            %% ACL check failed, deny access
            riak_cs_wm_utils:deny_access(RD, Ctx)
    end.



%% Illegal call, thus should not match.
%% bucket_access_authorize_helper(_RD, _Ctx, _AccessType, _Deletable)->
%%     ok.

%% ===================================================================
%% Internal functions
%% ===================================================================

any_to_list(V) when is_list(V) ->
    V;
any_to_list(V) when is_atom(V) ->
    atom_to_list(V);
any_to_list(V) when is_binary(V) ->
    binary_to_list(V);
any_to_list(V) when is_integer(V) ->
    integer_to_list(V).

%% @doc Get an ISO 8601 formatted timestamp representing
%% current time.
-spec iso_8601_format(pos_integer(),
                      pos_integer(),
                      pos_integer(),
                      non_neg_integer(),
                      non_neg_integer(),
                      non_neg_integer()) -> string().
iso_8601_format(Year, Month, Day, Hour, Min, Sec) ->
    lists:flatten(
     io_lib:format("~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~2.10.0B.000Z",
                   [Year, Month, Day, Hour, Min, Sec])).

b2i(Bin) ->
    list_to_integer(binary_to_list(Bin)).
