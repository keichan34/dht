% @author Uvarov Michail <arcusfelis@gmail.com>

-module(etorrent_info).
-behaviour(gen_server).

-define(AWAIT_TIMEOUT, 10*1000).
-define(DEFAULT_CHUNK_SIZE, 16#4000). % TODO - get this value from a configuration file
-define(METADATA_BLOCK_BYTE_SIZE, 16384). %% 16KiB (16384 Bytes) 


-export([start_link/2,
         register_server/1,
         lookup_server/1,
         await_server/1]).

-export([get_mask/2,
         get_mask/4,
         mask_to_filelist/2,
         tree_children/2,
         minimize_filelist/2]).

%% Info API
-export([long_file_name/2,
         file_name/2,
         full_file_name/2,
         file_position/2,
         file_size/2,         %
         piece_size/1,        %
         piece_count/1,       %
         chunk_size/1         %
        ]).

%% Metadata API (BEP-9)
-export([metadata_size/1,
         get_piece/2]).

-export([
	init/1,
	handle_cast/2,
	handle_call/3,
	handle_info/2,
	terminate/2,
	code_change/3]).


-type bcode() :: etorrent_types:bcode().
-type torrent_id() :: etorrent_types:torrent_id().
-type file_id() :: etorrent_types:file_id().
-type pieceset() :: etorrent_pieceset:t().

-define(ROOT_FILE_ID, 0).

-record(state, {
    torrent :: torrent_id(),
    static_file_info :: array(),
    total_size :: non_neg_integer(),
    piece_size :: non_neg_integer(),
    chunk_size = ?DEFAULT_CHUNK_SIZE :: non_neg_integer(),
    piece_count :: non_neg_integer(),
    metadata_size :: non_neg_integer(),
    metadata_pieces :: [binary()]
    }).


-record(file_info, {
    id :: file_id(),
    %% Relative name, used in file_sup
    name :: string(),
    %% Label for nodes of cascadae file tree
    short_name :: binary(),
    type      = file :: directory | file,
    children  = [] :: [file_id()],
    % How many files are in this node?
    capacity  = 0 :: non_neg_integer(),
    size      = 0 :: non_neg_integer(),
    % byte offset from 0
    position  = 0 :: non_neg_integer(),
    pieces :: etorrent_pieceset:t()
}).

%% @doc Start the File I/O Server
%% @end
-spec start_link(torrent_id(), bcode()) -> {'ok', pid()}.
start_link(TorrentID, Torrent) ->
    gen_server:start_link(?MODULE, [TorrentID, Torrent], [{timeout,15000}]).



server_name(TorrentID) ->
    {etorrent, TorrentID, info}.


%% @doc
%% Register the current process as the directory server for
%% the given torrent.
%% @end
-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

%% @doc
%% Lookup the process id of the directory server responsible
%% for the given torrent. If there is no such server registered
%% this function will crash.
%% @end
-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

%% @doc
%% Wait for the directory server for this torrent to appear
%% in the process registry.
%% @end
-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID), ?AWAIT_TIMEOUT).



%% @doc Build a mask of the file in the torrent.
-spec get_mask(torrent_id(), file_id()) -> pieceset().
get_mask(TorrentID, FileID) when is_integer(FileID) ->
    DirPid = await_server(TorrentID),
    {ok, Mask} = gen_server:call(DirPid, {get_mask, FileID}),
    Mask;

%% List of files with same priority.
get_mask(TorrentID, [_|_] = IdList) ->
    true = lists:all(fun is_integer/1, IdList),
    DirPid = await_server(TorrentID),
    MapFn = fun(FileID) ->
            {ok, Mask} = gen_server:call(DirPid, {get_mask, FileID}),
            Mask
        end,

    %% Do map
    Masks = lists:map(MapFn, IdList),
    %% Do reduce
    etorrent_pieceset:union(Masks);

get_mask(TorrentID, []) ->
    DirPid = await_server(TorrentID),
    {ok, PieceCount} = gen_server:call(DirPid, piece_count),
    etorrent_pieceset:empty(PieceCount).
   
 
%% @doc Build a mask of the part of the file in the torrent.
get_mask(TorrentID, FileID, PartStart, PartSize)
    when PartStart >= 0, PartSize >= 0, 
            is_integer(TorrentID), is_integer(FileID) ->
    DirPid = await_server(TorrentID),
    {ok, Mask} = gen_server:call(DirPid, {get_mask, FileID, PartStart, PartSize}),
    Mask.


%% @doc Returns ids of each file, all pieces of that are in the pieceset `Mask'.
mask_to_filelist(TorrentID, Mask) ->
    DirPid = await_server(TorrentID),
    {ok, List} = gen_server:call(DirPid, {mask_to_filelist, Mask}),
    List.



piece_size(TorrentID) when is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Size} = gen_server:call(DirPid, piece_size),
    Size.


chunk_size(TorrentID) when is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Size} = gen_server:call(DirPid, chunk_size),
    Size.


piece_count(TorrentID) when is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Count} = gen_server:call(DirPid, piece_count),
    Count.


file_position(TorrentID, FileID) when is_integer(TorrentID), is_integer(FileID) ->
    DirPid = await_server(TorrentID),
    {ok, Pos} = gen_server:call(DirPid, {position, FileID}),
    Pos.


file_size(TorrentID, FileID) when is_integer(TorrentID), is_integer(FileID) ->
    DirPid = await_server(TorrentID),
    {ok, Size} = gen_server:call(DirPid, {size, FileID}),
    Size.


-spec tree_children(torrent_id(), file_id()) -> [{atom(), term()}].
tree_children(TorrentID, FileID) when is_integer(TorrentID), is_integer(FileID) ->
    %% get children
    DirPid = await_server(TorrentID),
    {ok, Records} = gen_server:call(DirPid, {tree_children, FileID}),

    %% get valid pieceset
    CtlPid = etorrent_torrent_ctl:lookup_server(TorrentID),    
    {ok, Valid} = etorrent_torrent_ctl:valid_pieces(CtlPid),

    lists:map(fun(X) ->
            ValidFP = etorrent_pieceset:intersection(X#file_info.pieces, Valid),
            SizeFP = etorrent_pieceset:size(X#file_info.pieces),
            ValidSizeFP = etorrent_pieceset:size(ValidFP),
            [{id, X#file_info.id}
            ,{name, X#file_info.short_name}
            ,{size, X#file_info.size}
            ,{capacity, X#file_info.capacity}
            ,{is_leaf, (X#file_info.children == [])}
            ,{progress, ValidSizeFP / SizeFP}
            ]
        end, Records).
    

%% @doc Form minimal version of the filelist with the same pieceset.
minimize_filelist(TorrentID, FileIds) when is_integer(TorrentID) ->
    SortedFiles = lists:sort(FileIds),
    DirPid = await_server(TorrentID),
    {ok, Ids} = gen_server:call(DirPid, {minimize_filelist, SortedFiles}),
    Ids.
    

%% @doc This name is used in cascadae wish view.
-spec long_file_name(torrent_id(), file_id() | [file_id()]) -> binary().
long_file_name(TorrentID, FileID) when is_integer(FileID) ->
    long_file_name(TorrentID, [FileID]);

long_file_name(TorrentID, FileID) when is_list(FileID), is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Name} = gen_server:call(DirPid, {long_file_name, FileID}),
    Name.


full_file_name(TorrentID, FileID) when is_integer(FileID), is_integer(TorrentID) ->
    RelName = file_name(TorrentID, FileID),
    FileServer = etorrent_io:lookup_file_server(TorrentID, RelName),
    {ok, Name} = etorrent_io_file:full_path(FileServer),
    Name.


%% @doc Convert FileID to relative file name.
file_name(TorrentID, FileID) when is_integer(FileID) ->
    DirPid = await_server(TorrentID),
    {ok, Name} = gen_server:call(DirPid, {file_name, FileID}),
    Name.
    

-spec metadata_size(torrent_id()) -> non_neg_integer().
metadata_size(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Len} = gen_server:call(DirPid, metadata_size),
    Len.

%% Piece is indexed from 0.
get_piece(TorrentID, PieceNum) when is_integer(PieceNum) ->
    DirPid = await_server(TorrentID),
    {ok, PieceData} = gen_server:call(DirPid, {get_piece, PieceNum}),
    PieceData.

%% ----------------------------------------------------------------------

%% @private
init([TorrentID, Torrent]) ->
    Info = collect_static_file_info(Torrent),

    {Static, PLen, TLen} = Info,

    true = register_server(TorrentID),

    MetaInfo = etorrent_bcoding:get_value("info", Torrent),
    %% Really? First decode, now encode...
    TorrentBin = iolist_to_binary(etorrent_bcoding:encode(MetaInfo)),
    MetadataSize = byte_size(TorrentBin),

    InitState = #state{
        torrent=TorrentID,
        static_file_info=Static,
        total_size=TLen, 
        piece_size=PLen,
        piece_count=byte_to_piece_count(TLen, PLen),
        metadata_size = MetadataSize,
        metadata_pieces = list_to_tuple(metadata_pieces(TorrentBin, 0, MetadataSize))
    },
    {ok, InitState}.


%% @private

handle_call({get_info, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        X=#file_info{} ->
            {reply, {ok, X}, State}
    end;

handle_call({position, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        #file_info{position=P} ->
            {reply, {ok, P}, State}
    end;

handle_call({size, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        #file_info{size=Size} ->
            {reply, {ok, Size}, State}
    end;

handle_call(chunk_size, _, State=#state{chunk_size=S}) ->
    {reply, {ok, S}, State};

handle_call(piece_size, _, State=#state{piece_size=S}) ->
    {reply, {ok, S}, State};

handle_call(piece_count, _, State=#state{piece_count=C}) ->
    {reply, {ok, C}, State};

handle_call({get_mask, FileID, PartStart, PartSize}, _, State) ->
    #state{static_file_info=Arr, total_size=TLen, piece_size=PLen} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        #file_info {position = FileStart} ->
            %% true = PartSize =< FileSize,

            %% Start from beginning of the torrent
            From = FileStart + PartStart,
            Mask = make_mask(From, PartSize, PLen, TLen),
            Set = etorrent_pieceset:from_bitstring(Mask),

            {reply, {ok, Set}, State}
    end;
    
handle_call({get_mask, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        #file_info {pieces = Mask} ->
            {reply, {ok, Mask}, State}
    end;

handle_call({long_file_name, FileIDs}, _, State) ->
    #state{static_file_info=Arr} = State,

    F = fun(FileID) -> 
            Rec = array:get(FileID, Arr), 
            Rec#file_info.name
       end,

    Reply = try 
        NameList = lists:map(F, FileIDs),
        NameBinary = list_to_binary(string:join(NameList, ", ")),
        {ok, NameBinary}
        catch error:_ ->
            lager:error("List of ids ~w caused an error.", 
                [FileIDs]),
            {error, badid}
        end,
            
    {reply, Reply, State};

handle_call({file_name, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
    undefined ->
       {reply, {error, badid}, State};
    #file_info {name = Name} ->
       {reply, {ok, Name}, State}
    end;

handle_call({minimize_filelist, FileIDs}, _, State) ->
    #state{static_file_info=Arr} = State,
    RecList = [ array:get(FileID, Arr) || FileID <- FileIDs ],
    FilteredIDs = [Rec#file_info.id || Rec <- minimize_reclist(RecList)],
    {reply, {ok, FilteredIDs}, State};

handle_call({tree_children, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        #file_info {children = Ids} ->
            Children = [array:get(Id, Arr) || Id <- Ids],
            {reply, {ok, Children}, State}
    end;
handle_call(metadata_size, _, State) ->
    #state{metadata_size=MetadataSize} = State,
    {reply, {ok, MetadataSize}, State};
handle_call({get_piece, PieceNum}, _, State=#state{metadata_pieces=Pieces})
        when PieceNum < tuple_size(Pieces) ->
    {reply, {ok, element(PieceNum+1, Pieces)}, State};
handle_call({get_piece, PieceNum}, _, State=#state{}) ->
    {reply, {ok, {bad_piece, PieceNum}}, State};

handle_call({mask_to_filelist, Mask}, _, State=#state{}) ->
    #state{static_file_info=Arr} = State,
    List = mask_to_filelist_int(Mask, Arr),
    {reply, {ok, List}, State}.


%% @private
handle_cast(Msg, State) ->
    lager:warning("Spurious handle cast: ~p", [Msg]),
    {noreply, State}.
    

%% @private
handle_info(Msg, State) ->
    lager:warning("Spurious handle info: ~p", [Msg]),
    {noreply, State}.

%% @private
terminate(_, _) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ----------------------------------------------------------------------



%% -\/-----------------FILE INFO API----------------------\/-
%% @private
collect_static_file_info(Torrent) ->
    PieceLength = etorrent_metainfo:get_piece_length(Torrent),
    FileLengths = etorrent_metainfo:file_path_len(Torrent),
    %% Rec1, Rec2, .. are lists of nodes.
    %% Calculate positions, create records. They are still not prepared.
    {TLen, Rec1} = flen_to_record(FileLengths, 0, []),
    %% Add directories as additional nodes.
    [#file_info{size=TLen2}|_] = Rec2 = add_directories(Rec1),
    assert_total_length(TLen, TLen2),
    %% Fill `pieces' field.
    %% A mask is a set of pieces which contains the file.
    Rec3 = fill_pieces(Rec2, PieceLength, TLen),
    Rec4 = fill_ids(Rec3),
    {array:from_list(Rec4), PieceLength, TLen}.


%% @private
flen_to_record([{Name, FLen} | T], From, Acc) ->
    To = From + FLen,
    X = #file_info {
        type = file,
        name = Name,
        position = From,
        size = FLen
    },
    flen_to_record(T, To, [X|Acc]);

flen_to_record([], TotalLen, Acc) ->
    {TotalLen, lists:reverse(Acc)}.


%% @private
add_directories(Rec1) ->
    Idx = 1,
    {Rec2, Children, Idx1, []} = add_directories_(Rec1, Idx, "", [], []),
    [Last|_] = Rec2,
    Rec3 = lists:reverse(Rec2),

    #file_info {
        size = LastSize,
        position = LastPos
    } = Last,

    Root = #file_info {
        name = "",
        % total size
        size = (LastSize + LastPos),
        position = 0,
        children = Children,
        capacity = Idx1 - Idx
    },

    [Root|Rec3].


%% "test/t1.txt"
%% "t2.txt"
%% "dir1/dir/x.x"
%% ==>
%% "."
%% "test"
%% "test/t1.txt"
%% "t2.txt"
%% "dir1"
%% "dir1/dir"
%% "dir1/dir/x.x"

%% @private
dirname_(Name) ->
    case filename:dirname(Name) of
        "." -> "";
        Dir -> Dir
    end.

%% @private
first_token_(Path) ->
    case filename:split(Path) of
    ["/", Token | _] -> Token;
    [Token | _] -> Token
    end.

%% @private
file_join_(L, R) ->
    case filename:join(L, R) of
        "/" ++ X -> X;
        X -> X
    end.

file_prefix_(S1, S2) ->
    lists:prefix(filename:split(S1), filename:split(S2)).


%% @private
add_directories_([], Idx, _Cur, Children, Acc) ->
    {Acc, lists:reverse(Children), Idx, []};

%% @private
add_directories_([H|T], Idx, Cur, Children, Acc) ->
    #file_info{ name = Name, position = CurPos } = H,
    Dir = dirname_(Name),
    Action = case Dir of
            Cur -> 'equal';
            _   ->
                case file_prefix_(Cur, Dir) of
                    true -> 'prefix';
                    false -> 'other'
                end
        end,

    case Action of
        %% file is in the same directory
        'equal' ->
            add_directories_(T, Idx+1, Dir, [Idx|Children], [H|Acc]);

        %% file is in child directory
        'prefix' ->
            Sub = Dir -- Cur,
            Part = first_token_(Sub),
            NextDir = file_join_(Cur, Part),

            {SubAcc, SubCh, Idx1, SubT} 
                = add_directories_([H|T], Idx+1, NextDir, [], []),
            [#file_info{ position = LastPos, size = LastSize }|_] = SubAcc,

            DirRec = #file_info {
                name = NextDir,
                size = (LastPos + LastSize - CurPos),
                position = CurPos,
                children = SubCh,
                capacity = Idx1 - Idx
            },
            NewAcc = SubAcc ++ [DirRec|Acc],
            add_directories_(SubT, Idx1, Cur, [Idx|Children], NewAcc);
        
        %% file is in the other directory
        'other' ->
            {Acc, lists:reverse(Children), Idx, [H|T]}
    end.


%% @private
fill_pieces(RecList, PLen, TLen) ->
    F = fun(#file_info{position = From, size = Size} = Rec) ->
            Mask = make_mask(From, Size, PLen, TLen),
            Set = etorrent_pieceset:from_bitstring(Mask),
            Rec#file_info{pieces = Set}
        end,
        
    lists:map(F, RecList).    


fill_ids(RecList) ->
    fill_ids_(RecList, 0, []).

fill_ids_([H1=#file_info{name=Name}|T], Id, Acc) ->
    % set id, prepare name for cascadae
    H2 = H1#file_info{
        id = Id,
        short_name = list_to_binary(filename:basename(Name))
    },
    fill_ids_(T, Id+1, [H2|Acc]);
fill_ids_([], _Id, Acc) ->
    lists:reverse(Acc).


%% @private
make_mask(From, Size, PLen, TLen)
    when PLen =< TLen, Size =< TLen, From >= 0, PLen > 0 ->
    %% __Bytes__: 1 <= From <= To <= TLen
    %%
    %% Calculate how many __pieces__ before, in and after the file.
    %% Be greedy: when the file ends inside a piece, then put this piece
    %% both into this file and into the next file.
    %% [0..X1 ) [X1..X2] (X2..MaxPieces]
    %% [before) [  in  ] (    after    ]
    PTotal = byte_to_piece_count(TLen, PLen),

    %% indexing from 0
    PFrom  = byte_to_piece_index(From, PLen),

    PBefore = PFrom,
    PIn     = byte_to_piece_count_beetween(From, Size, PLen),
    PAfter  = PTotal - PIn - PBefore,
    assert_positive(PBefore),
    assert_positive(PIn),
    assert_positive(PAfter),
    <<0:PBefore, -1:PIn, 0:PAfter>>.


%% @private
minimize_reclist(RecList) ->
    minimize_(RecList, []).


minimize_([H|T], []) ->
    minimize_(T, [H]);


%% H is a ancestor of the previous element. Skip H.
minimize_([ #file_info{position=Pos} | T ], 
    [#file_info{size=PrevSize, position=PrevPos}|_] = Acc)
    when Pos < (PrevPos + PrevSize) ->
    minimize_(T, Acc);

minimize_([H|T], Acc) ->
    minimize_(T, [H|Acc]);

minimize_([], Acc) ->
    lists:reverse(Acc).
    
    
%% -/\-----------------FILE INFO API----------------------/\-



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

make_mask_test_() ->
    F = fun make_mask/4,
    % make_index(From, Size, PLen, TLen)
    %% |0123|4567|89A-|
    %% |--xx|x---|----|
    [?_assertEqual(<<2#110:3>>        , F(2, 3,  4, 10))
    %% |012|345|678|9A-|
    %% |--x|xx-|---|---|
    ,?_assertEqual(<<2#1100:4>>       , F(2, 3,  3, 10))
    %% |01|23|45|67|89|A-|
    %% |--|xx|x-|--|--|--|
    ,?_assertEqual(<<2#01100:5>>      , F(2, 3,  2, 10))
    %% |0|1|2|3|4|5|6|7|8|9|A|
    %% |-|-|x|x|x|-|-|-|-|-|-|
    ,?_assertEqual(<<2#0011100000:10>>, F(2, 3,  1, 10))
    ,?_assertEqual(<<1:1>>            , F(2, 3, 10, 10))
    ,?_assertEqual(<<1:1, 0:1>>       , F(2, 3,  9, 10))
    %% |012|345|678|9A-|
    %% |xxx|xx-|---|---|
    ,?_assertEqual(<<2#1100:4>>       , F(0, 5,  3, 10))
    %% |012|345|678|9A-|
    %% |---|---|--x|---|
    ,?_assertEqual(<<2#0010:4>>       , F(8, 1,  3, 10))
    %% |012|345|678|9A-|
    %% |---|---|--x|x--|
    ,?_assertEqual(<<2#0011:4>>       , F(8, 2,  3, 10))
    ,?_assertEqual(<<-1:30>>, F(0, 31457279,  1048576, 31457280))
    ,?_assertEqual(<<-1:30>>, F(0, 31457280,  1048576, 31457280))
    ].

add_directories_test_() ->
    Rec = add_directories(
        [#file_info{position=0, size=3, name="test/t1.txt"}
        ,#file_info{position=3, size=2, name="t2.txt"}
        ,#file_info{position=5, size=1, name="dir1/dir/x.x"}
        ,#file_info{position=6, size=2, name="dir1/dir/x.y"}
        ]),
    Names = el(Rec, #file_info.name),
    Sizes = el(Rec, #file_info.size),
    Positions = el(Rec, #file_info.position),
    Children  = el(Rec, #file_info.children),

    [Root|Elems] = Rec,
    MinNames  = el(minimize_reclist(Elems), #file_info.name),
    
    %% {NumberOfFile, Name, Size, Position, ChildNumbers}
    List = [{0, "",             8, 0, [1, 3, 4]}
           ,{1, "test",         3, 0, [2]}
           ,{2, "test/t1.txt",  3, 0, []}
           ,{3, "t2.txt",       2, 3, []}
           ,{4, "dir1",         3, 5, [5]}
           ,{5, "dir1/dir",     3, 5, [6, 7]}
           ,{6, "dir1/dir/x.x", 1, 5, []}
           ,{7, "dir1/dir/x.y", 2, 6, []}
        ],
    ExpNames = el(List, 2),
    ExpSizes = el(List, 3),
    ExpPositions = el(List, 4),
    ExpChildren  = el(List, 5),
    
    [?_assertEqual(Names, ExpNames)
    ,?_assertEqual(Sizes, ExpSizes)
    ,?_assertEqual(Positions, ExpPositions)
    ,?_assertEqual(Children,  ExpChildren)
    ,?_assertEqual(MinNames, ["test", "t2.txt", "dir1"])
    ].


el(List, Pos) ->
    Children  = [element(Pos, X) || X <- List].



add_directories_test() ->
    [Root|_] =
    add_directories(
        [#file_info{position=0, size=3, name=
    "BBC.7.BigToe/Eoin Colfer. Artemis Fowl/artemis_04.mp3"}
        ,#file_info{position=3, size=2, name=
    "BBC.7.BigToe/Eoin Colfer. Artemis Fowl. The Arctic Incident/artemis2_03.mp3"}
        ]),
    ?assertMatch(#file_info{position=0, size=5}, Root).

% H = {file_info,undefined,
%           "BBC.7.BigToe/Eoin Colfer. Artemis Fowl. The Arctic Incident/artemis2_03.mp3",
%           undefined,file,[],0,5753284,1633920175,undefined}
% NextDir =  "BBC.7.BigToe/Eoin Colfer. Artemis Fowl/. The Arctic Incident


metadata_pieces_test_() ->
    crypto:start(),
    TorrentBin = crypto:rand_bytes(100000),
    Pieces = metadata_pieces(TorrentBin, 0, byte_size(TorrentBin)),
    [Last|InitR] = lists:reverse(Pieces),
    F = fun(Piece) -> byte_size(Piece) =:= ?METADATA_BLOCK_BYTE_SIZE end,
    [?_assertEqual(iolist_to_binary(Pieces), TorrentBin)
    ,?_assert(byte_size(Last) =< ?METADATA_BLOCK_BYTE_SIZE)
    ,?_assert(lists:all(F, InitR))
    ].

-endif.


%% Not last.
metadata_pieces(TorrentBin, From, MetadataSize)
    when MetadataSize > ?METADATA_BLOCK_BYTE_SIZE ->
    [binary:part(TorrentBin, {From,?METADATA_BLOCK_BYTE_SIZE})
    |metadata_pieces(TorrentBin,
                     From+?METADATA_BLOCK_BYTE_SIZE, 
                     MetadataSize-?METADATA_BLOCK_BYTE_SIZE)];

%% Last.
metadata_pieces(TorrentBin, From, MetadataSize) ->
    [binary:part(TorrentBin, {From,MetadataSize})].


assert_total_length(TLen, TLen) ->
    ok;
assert_total_length(TLen, TLen2) ->
    error({assert_total_length, TLen, TLen2}).


assert_positive(X) when X >= 0 ->
    ok;
assert_positive(X) ->
    error({assert_positive, X}).


byte_to_piece_count(TLen, PLen) ->
    (TLen div PLen) + case TLen rem PLen of 0 -> 0; _ -> 1 end.

byte_to_piece_index(TLen, PLen) ->
    TLen div PLen.


%% Bytes:  |0123|4567|89AB|
%% Pieces: |0   |1   |2   |
%% Set:    |---x|xxxx|xxx-|
%% From:   3
%% Size:   8
%% PLen:   4
%% Left:   1
%% Right:  3
%% Mid:    4
%% PLeft:  1
%% PRight: 1
%% PMid:   1
byte_to_piece_count_beetween(From, Size, PLen) ->
    To     = From + Size,
    Left   = case From rem PLen of 0 -> 0; X -> PLen - X end,
    Right  = To rem PLen,
    Mid    = Size - Left - Right,
    PLeft  = case Left  of 0 -> 0; _ -> 1 end,
    PRight = case Right of 0 -> 0; _ -> 1 end,
    PMid   = Mid div PLen,
    %% assert
    0      = Mid rem PLen,
    PMid + PLeft + PRight.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
byte_to_piece_count_beetween_test_() ->
    [?_assertEqual(3, byte_to_piece_count_beetween(3, 8, 4))
    ,?_assertEqual(0, byte_to_piece_count_beetween(0, 0, 10))
    ,?_assertEqual(1, byte_to_piece_count_beetween(0, 1, 10))
    ,?_assertEqual(1, byte_to_piece_count_beetween(0, 9, 10))
    ,?_assertEqual(1, byte_to_piece_count_beetween(0, 10, 10))
    ,?_assertEqual(2, byte_to_piece_count_beetween(0, 11, 10))
    ,?_assertEqual(2, byte_to_piece_count_beetween(1, 10, 10))
    ,?_assertEqual(2, byte_to_piece_count_beetween(1, 11, 10))
    ].

-endif.



%% Internal.
mask_to_filelist_int(Mask, Arr) ->
    Root = array:get(?ROOT_FILE_ID, Arr),
    case Root of
        %% Everything is unwanted.
        #file_info{pieces=Mask} ->
            [0];
        #file_info{children=SubFileIds} ->
            mask_to_filelist_rec(SubFileIds, Mask, Arr)
    end.

%% Matching all files starting from Root recursively.
mask_to_filelist_rec([FileId|FileIds], Mask, Arr) ->
    #file_info{pieces=FileMask, children=SubFileIds} = array:get(FileId, Arr),
    Diff = etorrent_pieceset:difference(FileMask, Mask),
    case etorrent_pieceset:is_empty(Diff) of
        true ->
            %% The whole file is matched.
            [FileId|mask_to_filelist_rec(FileIds, Mask, Arr)];
        false ->
            %% Check childrens.
            mask_to_filelist_rec(SubFileIds, Mask, Arr) ++
            mask_to_filelist_rec(FileIds, Mask, Arr)
    end;
mask_to_filelist_rec([], _Mask, _Arr) ->
    [].

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

mask_to_filelist_int_test_() ->
    FileName = filename:join(code:lib_dir(etorrent_core), 
                             "test/etorrent_eunit_SUITE_data/coulton.torrent"),
    {ok, Torrent} = etorrent_bcoding:parse_file(FileName),
    Info = collect_static_file_info(Torrent),
    {Arr, _PLen, _TLen} = Info,
    N2I     = file_name_to_ids(Arr),
    FileId  = fun(Name) -> dict:fetch(Name, N2I) end,
    Pieces  = fun(Id) -> #file_info{pieces=Ps} = array:get(Id, Arr), Ps end,
    Week4   = FileId("Jonathan Coulton/Thing a Week 4"),
    BigBoom = FileId("Jonathan Coulton/Thing a Week 4/The Big Boom.mp3"),
    Ikea    = FileId("Jonathan Coulton/Smoking Monkey/04 Ikea.mp3"),
    Week4Pieces   = Pieces(Week4),
    BigBoomPieces = Pieces(BigBoom),
    IkeaPieces    = Pieces(Ikea),
    W4BBPieces    = etorrent_pieceset:union(Week4Pieces, BigBoomPieces),
    W4IkeaPieces  = etorrent_pieceset:union(Week4Pieces, IkeaPieces),
    [?_assertEqual([Week4], mask_to_filelist_int(Week4Pieces, Arr))
    ,?_assertEqual([Week4], mask_to_filelist_int(W4BBPieces, Arr))
    ,?_assertEqual([Ikea, Week4], mask_to_filelist_int(W4IkeaPieces, Arr))
    ].

file_name_to_ids(Arr) ->
    F = fun(FileId, #file_info{name=Name}, Acc) -> [{Name, FileId}|Acc] end,
    dict:from_list(array:foldl(F, [], Arr)).


-endif.
