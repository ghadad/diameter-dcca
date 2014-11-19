%%
%% The diameter application callback module configured by server.erl.
%%

-module(server_cb).

-include_lib("diameter/include/diameter.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc3588.hrl").
-include_lib("rfc4006_cc_Gy.hrl").
-include_lib("diameter_settings.hrl").

-define(DIA_STATS_TAB, dcca_stats).

%% diameter callbacks
-export([peer_up/3,
         peer_down/3,
         pick_peer/4,
         prepare_request/3,
         prepare_retransmit/3,
         handle_answer/4,
         handle_error/4,
         handle_request/3]).

-define(UNEXPECTED, erlang:error({unexpected, ?MODULE, ?LINE})).

peer_up(_SvcName, {PeerRef, _}, State) ->
    error_logger:info_msg("Peer up: ~p~n", [PeerRef]),
    State.

peer_down(_SvcName, {PeerRef, _}, State) ->
    error_logger:info_msg("Peer down: ~p~n", [PeerRef]),
    State.

pick_peer(_, _, _SvcName, _State) ->
    ?UNEXPECTED.

prepare_request(_, _SvcName, _Peer) ->
    ?UNEXPECTED.

prepare_retransmit(_Packet, _SvcName, _Peer) ->
    ?UNEXPECTED.

handle_answer(_Packet, _Request, _SvcName, _Peer) ->
    ?UNEXPECTED.

handle_error(_Reason, _Request, _SvcName, _Peer) ->
    error_logger:error_msg("Request error: ~p~n", [_Reason]),
    ?UNEXPECTED.

%% A request whose decode was successful ...
handle_request(#diameter_packet{msg = Req, errors = []}, _SvcName, {_, Caps})
  when is_record(Req, rfc4006_cc_Gy_CCR) ->
    #diameter_caps{origin_host = {OH,_},
                   origin_realm = {OR,_}
    } = Caps,
    #rfc4006_cc_Gy_CCR{
       'Session-Id' = SessionId,
       'Auth-Application-Id' = ?DCCA_APPLICATION_ID,
       'CC-Request-Type' = RT,
       'CC-Request-Number' = RN,
       % 'Service-Context-Id' = ServiceContextId,
       'Event-Timestamp' = EventTimestamp,
       'Subscription-Id' = SUBSCRIPTION,
       'Multiple-Services-Credit-Control' = MSCC,
       'Called-Station-Id' = APN
       % 'Service-Information' = [ServiceInformation]
    } = Req,
    MSISDN = getSubscriptionId(?'MSISDN', SUBSCRIPTION),
    IMSI = getSubscriptionId(?'IMSI', SUBSCRIPTION),
    %io:format("Record:~n~p~n", [lists:zip(record_info(fields, rfc4006_cc_Gy_CCR), tl(tuple_to_list(Req)))]),

    error_logger:info_msg(
        "
        ------------------------------> Req. Number ~p <------------------------------
        CCR OK: ~p
        MSCC: ~p
        ------------------------------------------------------------------------------
        ", [RN, Req, MSCC]),
    MSCC_Data = process_mscc(RT, MSCC, {APN, IMSI, MSISDN, "10.0.0.1", SessionId, EventTimestamp}),
    {reply, answer(ok, RT, RN, SessionId, OH, OR, MSCC_Data)};


%% ... or one that wasn't. 3xxx errors are answered by diameter itself
%% but these are 5xxx errors for which we must contruct a reply.
%% diameter will set Result-Code and Failed-AVP's.
handle_request(#diameter_packet{msg = Req, errors = Err}, _SvcName, {_, Caps})
  when is_record(Req, rfc4006_cc_Gy_CCR) ->
    #diameter_caps{origin_host = {OH,_},
                   origin_realm = {OR,_}}
        = Caps,
    #rfc4006_cc_Gy_CCR{'Session-Id' = Id,
                    'CC-Request-Type' = RT,
                    'CC-Request-Number'= RN,
                    'Multiple-Services-Credit-Control' = MSCC,
                    'Called-Station-Id' = APN
                    }
        = Req,
    error_logger:error_msg(
        "
        ------------------------------> Req. Number ~p <------------------------------
        CCR: ~p
        Error: ~p
        APN: ~p
        MSCC: ~p
        ------------------------------------------------------------------------------
        ", [RN, Req, Err, APN, MSCC]),
    {reply, answer(err, RT, RN, Id, OH, OR, [])};

%% Should really reply to other base messages that we don't support
%% but simply discard them instead.
handle_request(#diameter_packet{}, _SvcName, {_,_}) ->
    error_logger:error_msg("Unsupported message.~n"),
    discard.

getSubscriptionId(TYPE, [SUBS|T]) ->
    % io:format("getSubscriptionId: ~w, ~w , ~w ~n",[TYPE, SUBS, T]),
    #'rfc4006_cc_Gy_Subscription-Id'{
        'Subscription-Id-Type' = Type,
        'Subscription-Id-Data' = Data
    } = SUBS,
    case Type of
        TYPE ->
            Data;
        _ ->
            getSubscriptionId(TYPE, T)
        end;
getSubscriptionId(_, []) ->
    err.


process_mscc(RT, [MSCC|T], {APN, IMSI, MSISDN, Location, SessionId, EventTimestamp}) ->
    common_stats:inc(?DIA_STATS_TAB, dia_input_update_OK),
    % io:format("Process_MSCC ~p~n", [MSCC]),
    % io:format("Process_MSCC T ~p~n", [T]),
    #'rfc4006_cc_Gy_Multiple-Services-Credit-Control' {
        'Used-Service-Unit' = USU,
        'Requested-Service-Unit' = RSU,
        'Service-Identifier' = [ServiceID],
        'Rating-Group' = [RatingGroup]
    } = MSCC,
    % io:format("USU: ~w~n",[USU]),
    % io:format("RSU: ~w~n",[RSU]),
    case {RSU, USU} of
        % Have RSU. No USU (First interrogation)
        {[_], []} ->
            io:format("Have RSU. No USU (First interrogation)~n"),
            {ResultCode, GrantedUnits} = ocs_intm:generate_req(initial, {APN, IMSI, MSISDN, Location, SessionId, EventTimestamp, 0, ServiceID, RatingGroup});
        % Have RSU. Have USU (Next interrogation)
        {[_], [_]} ->
            [#'rfc4006_cc_Gy_Used-Service-Unit' {
             'CC-Total-Octets' = [UsedUnits]
            }] = USU,
            io:format("USU: ~w~n", [UsedUnits]),
            {ResultCode, GrantedUnits} = ocs_intm:generate_req(update, {APN, IMSI, MSISDN, Location, SessionId, EventTimestamp, UsedUnits, ServiceID, RatingGroup});
        % No RSU. Have USU (Last interrogation)
        {[], [_]} ->
            error_logger:info_msg("No RSU. Have USU (Last interrogation)"),
            [#'rfc4006_cc_Gy_Used-Service-Unit' {
             'CC-Total-Octets' = [UsedUnits]
            }] = USU,
            io:format("USU: ~w~n",[UsedUnits]),
            {ResultCode, GrantedUnits} = ocs_intm:generate_req(terminate, {APN, IMSI, MSISDN, Location, SessionId, EventTimestamp, UsedUnits, ServiceID, RatingGroup})
        end,
    [{ServiceID, RatingGroup, GrantedUnits, ResultCode}|process_mscc(RT, T, {APN, IMSI, MSISDN, Location, SessionId, EventTimestamp})];

process_mscc(_, [], {_, _, _, _, _, _}) ->
    [].

%% ---------------------------------------------------------------------------

%% Answer using the record or list encoding depending on
%% Re-Auth-Request-Type. This is just as an example. You would
%% typically just choose one, and this has nothing to do with the how
%% client.erl sends.

answer(ok, RT, RN, Id, OH, OR, MSCC) ->
  common_stats:inc(?DIA_STATS_TAB, event_OK),
  CCA = #rfc4006_cc_Gy_CCA {
    'Result-Code' = 2001, %% DIAMETER_SUCCESS
    'Origin-Host' = OH,
    'Origin-Realm' = OR,
    'Session-Id' = Id,
    'Auth-Application-Id' = ?DCCA_APPLICATION_ID,
    'CC-Request-Type' = RT,
    'CC-Request-Number' = RN,
    %'Termination-Cause' = [] %% Only used on TERMINATE
    'Multiple-Services-Credit-Control' = mscc_answer(MSCC)
  },
  CCA;

answer(err, RT, RN, Id, OH, OR, []) ->
    common_stats:inc(?DIA_STATS_TAB, event_ERR),
    CCA = #rfc4006_cc_Gy_CCA {
      'Result-Code' = 5012, %% DIAMETER_UNABLE_TO_COMPLY
      'Origin-Host' = OH,
      'Origin-Realm' = OR,
      'Session-Id' = Id,
      'Auth-Application-Id' = ?DCCA_APPLICATION_ID,
      'CC-Request-Type' = RT,
      'CC-Request-Number' = RN
    },
    CCA.

mscc_answer([MSCC|T]) ->
    % io:format("mscc_answer:~n"),
    % io:format("MSCC: ~p~n",[MSCC]),
    % io:format("T: ~w~n",[T]),
    {ServiceID, RatingGroup, GrantedUnits, _ResultCode} = MSCC,
    [#'rfc4006_cc_Gy_Multiple-Services-Credit-Control' {
      'Granted-Service-Unit' = [#'rfc4006_cc_Gy_Granted-Service-Unit' {
        'CC-Total-Octets' = [GrantedUnits],
        'CC-Input-Octets' = [],
        'CC-Output-Octets' = [],
        'CC-Service-Specific-Units' = [],
        'AVP' = []
      }],
      'Service-Identifier' = [ServiceID],
      'Rating-Group' = [RatingGroup],
      'Validity-Time' = [3600],
      'Result-Code' = [2001]
      %'Final-Unit-Indication' = [],
    }|mscc_answer(T)];

mscc_answer([]) ->
[].


%% Internal Functions

% Check list. If null, return zero, else return value.
% checkNullList([X]) -> X;
% checkNullList([]) -> 0.
