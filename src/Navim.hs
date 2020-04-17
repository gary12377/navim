{-# LANGUAGE OverloadedStrings #-}

module Navim where

import System.Directory
import System.Exit

import Data.Bool
import Data.List
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Traversable

import Control.Monad
import Control.Monad.IO.Class

import Brick.AttrMap
import Brick.Main
import Brick.Types
import Brick.Util
import Brick.Widgets.Border
import Brick.Widgets.Border.Style
import Brick.Widgets.Core

import Cursor.Simple.List.NonEmpty

import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events

-- Main
navim :: IO ()
navim = do
    initState <- buildState Nothing
    endState  <- defaultMain navimApp initState
    let navPath = join $ intersperse "/" $ reverse $ navHistory endState
    putStrLn navPath

data NavimState = NavimState
    { navimStatePaths :: NonEmptyCursor DirContent
    , navHistory :: [FilePath]
    , mode :: Mode
    } deriving (Show, Eq)

data Mode
    = Navigation -- normal file navigation
    | Colon      -- colon commands: ends when input is empty or enter pressed
        { colonInputReversed :: String }
    | Input      -- waiting for user input with a given prompt
        { prompt :: Prompt        -- TODO: maybe sum type for prompt?
        , responseReversed :: String -- TODO: different data structure for fast snoc?
        }
    deriving (Show, Eq)

data Prompt
    = CreateFile
    | CreateDirectory
    | Remove
    deriving (Show, Eq)

data ResourceName
    = ResourceName
    deriving (Show, Eq, Ord)

data DirContent
    = File FilePath
    | Directory FilePath
    deriving (Show, Eq, Ord)

getPath :: DirContent -> FilePath
getPath (File fp)      = fp
getPath (Directory fp) = fp

nonEmptyCursorReset :: NonEmptyCursor a -> NonEmptyCursor a
nonEmptyCursorReset = makeNonEmptyCursor . rebuildNonEmptyCursor

-- TUI App Components
navimApp :: App NavimState e ResourceName
navimApp = App
    { appDraw = drawNavim
    , appChooseCursor = showFirstCursor
    , appHandleEvent = handleEvent
    , appStartEvent = pure
    , appAttrMap = const $
          attrMap
              mempty
              [ ("file", fg white)
              , ("dir", fg brightCyan)
              , ("file" <> "selected", withStyle currentAttr underline)
              , ("dir" <> "selected", withStyle (bg green) underline)
              , ("header", fg white)
              ]
    }

-- State Transformer (and I don't mean the monad ;))
buildState :: Maybe NavimState -> IO NavimState
buildState prevState = do
    curdir      <- getCurrentDirectory
    rawContents <- getDirectoryContents curdir
    contents    <- for rawContents $ \fp ->
                       bool (Directory fp) (File fp) <$> doesFileExist fp
    case NE.nonEmpty contents of
        Nothing -> die "Should never happen (current directory \".\" always here)"
        Just ne ->
            --return $
            case prevState of
                Nothing -> do
                    curDir <- liftIO getCurrentDirectory
                    return NavimState
                        { navimStatePaths = makeNonEmptyCursor ne
                        , navHistory = reverse . splitOn '/' $ curDir
                        , mode = Navigation
                        }
                Just ps -> return ps
                    { navimStatePaths =
                          adjustCursor
                              (navimStatePaths ps)
                              (makeNonEmptyCursor ne)
                    }
  where
    adjustCursor oldNec = moveNextBy (length $ nonEmptyCursorPrev oldNec)
    moveNextBy 0 newNec = newNec
    moveNextBy n newNec = case nonEmptyCursorSelectNext newNec of
                               Nothing   -> newNec
                               Just nec' -> moveNextBy (n - 1) nec'
    splitOn _ [] = []
    splitOn c (s:ss)
      | c == s = splitOn c ss
      | otherwise = let (left, right) = break (== '/') (s:ss)
                        in left : splitOn c right

-- UI Drawer
drawNavim :: NavimState -> [Widget ResourceName]
drawNavim ns =
    [
      border (padRight Max $
         withAttr "header" (str "navim - a (WIP) file manager written in Haskell by Gary Feng"))
      <=>
      padBottom Max pathsWidget
      <=>
      statusBar
      <=>
      inputBar
    ]
  where
    pathsCursor = navimStatePaths ns

    pathsWidget =
        padRight Max
        . viewport ResourceName Vertical
        . vBox
        . mconcat
        $ [ drawFilePath False <$> reverse (nonEmptyCursorPrev pathsCursor)
          , [ visible
              . drawFilePath True
              $ nonEmptyCursorCurrent pathsCursor
            ]
          , drawFilePath False <$> nonEmptyCursorNext pathsCursor
          ]

    statusBar =
        str $ case mode ns of
            Input CreateFile _ ->
                "Enter the name of the file to be created"
            Input CreateDirectory _ ->
                "Enter the name of the directory to be created"
            Input Remove _ ->
                case nonEmptyCursorCurrent pathsCursor of
                    File name ->
                        mconcat
                            [ "Are you sure you want to remove the file "
                            , name
                            , "?"
                            ]
                    Directory "." ->
                        "You may not remove the current directory from within."
                    Directory ".." ->
                        "You may not remove the parent directory from within."
                    Directory name ->
                        mconcat
                            [ "Are you sure you want to remove the directory "
                            , name
                            , "?"
                            ]
            _ -> ('/':) . mconcat . intersperse "/" . reverse . navHistory $ ns

    inputBar =
        padRight Max $
            case mode ns of
                Navigation ->
                    str "-- NAVIGATION --"
                Colon reversedInput ->
                    withBottomCursor reversedInput
                Input CreateFile reversedInput ->
                    withBottomCursor $ reversedInput ++ reverse "File name: "
                Input CreateDirectory reversedInput ->
                    withBottomCursor $ reversedInput ++ reverse "Directory name: "
                Input Remove reversedInput ->
                    withBottomCursor $ reversedInput ++ reverse "Confirm (y/n): "

    withBottomCursor reversedInput =
        showCursor
            ResourceName
            (Location (textWidth reversedInput, 0))
            (str . reverse $ reversedInput)

drawFilePath :: Bool -> DirContent -> Widget n
drawFilePath selected dc = decorate . str . getPath $ dc
  where
    decorate =
        withAttr
        . bool id (<> "selected") selected
        $ case dc of
              File      _ -> "file"
              Directory _ -> "dir"

-- Event Handler
handleEvent :: NavimState -> BrickEvent n e -> EventM n (Next NavimState)
handleEvent s e =
    case e of
        VtyEvent vtye ->
            case vtye of
                EvKey key@(KChar ':') [] ->
                    bottomInputOr (continue s { mode = Colon ":" }) key
                EvKey key@(KChar 'j') [] ->
                    bottomInputOr (moveCursorWith nonEmptyCursorSelectNext s) key
                EvKey key@(KChar 'k') [] ->
                    bottomInputOr (moveCursorWith nonEmptyCursorSelectPrev s) key
                EvKey key@(KChar 'n') [] ->
                    bottomInputOr (continue s { mode = Input CreateFile "" }) key
                EvKey key@(KChar 'n') [MMeta] ->
                    bottomInputOr (continue s { mode = Input CreateDirectory "" }) key
                EvKey key@(KChar 'd') [] ->
                    bottomInputOr (continue s { mode = Input Remove "" }) key
                EvKey key@(KChar _)   [] ->
                    bottomInputOr (continue s) key

                EvKey KDown [] -> moveCursorWith nonEmptyCursorSelectNext s
                EvKey KUp   [] -> moveCursorWith nonEmptyCursorSelectPrev s

                EvKey KBS    [] -> bottomInputOr (continue s) KBS
                EvKey KEnter [] -> bottomInputOr (performNavigate s) KEnter
                EvKey KEsc   [] -> continue s { mode = Navigation }
                _ -> continue s
        _ -> continue s
  where
    bottomInputOr :: EventM n (Next NavimState) -> Key -> EventM n (Next NavimState)
    bottomInputOr navAction key =
        case (mode s, key) of
            (Navigation, _) -> navAction

            -- TODO: lens please...
            (Colon input, KChar c) ->
                continue s { mode = Colon { colonInputReversed = c:input } }
            (Colon [c], KBS) ->
                continue s { mode = Navigation }
            (Colon (c:cs), KBS) ->
                continue s { mode = Colon { colonInputReversed = cs } }
            (Colon cs, KEnter) ->
                colonCommand s . reverse $ cs

            (inMode@(Input _ resp), KChar c) ->
                continue s { mode =  inMode { responseReversed = c:resp } }
            (inMode@(Input _ (c:cs)), KBS) ->
                continue s { mode =  inMode { responseReversed = cs } }
            (inMode@(Input _ ""), KBS) ->
                continue s { mode =  inMode { responseReversed = "" } }

            (Input Remove inp, KEnter) ->
                case nonEmptyCursorCurrent . navimStatePaths $ s of
                    Directory "."  -> continue s { mode = Navigation } -- TODO: no silent failure pls
                    Directory ".." -> continue s { mode = Navigation } -- TODO: no silent failure pls
                    _              -> inputCommand s Remove . reverse $ inp
            (Input pr inp, KEnter) ->
                inputCommand s pr . reverse $ inp

            (Input _ _, _) -> continue s -- TODO!!!!!!!!

            (_, _)        -> continue s

{- BEGIN Event Handler Helpers -}

moveCursorWith :: (NonEmptyCursor DirContent -> Maybe (NonEmptyCursor DirContent))
               -> NavimState
               -> EventM n (Next NavimState)
moveCursorWith move state =
    continue $
        case move (navimStatePaths state) of
            Nothing     -> state
            Just newNec -> state {navimStatePaths = newNec}

-- TODO: move cursor to parent directory when navigating on ".."
performNavigate :: NavimState -> EventM n (Next NavimState)
performNavigate s = case nonEmptyCursorCurrent . navimStatePaths $ s of
                        File      _  -> continue s
                        Directory fp -> do
                            liftIO $ setCurrentDirectory fp
                            let newHistory = case (navHistory s, fp) of
                                                 (ps  , "." )    -> ps
                                                 ([]  , "..")    -> []
                                                 (p:ps, "..")    -> ps
                                                 (ps  , next)    -> next:ps
                            s' <- liftIO . buildState $
                                      Just s { navimStatePaths =
                                                   nonEmptyCursorReset (navimStatePaths s)
                                             }
                            continue s' { navHistory = newHistory }

-- TODO: move this to a safe directory ops module?
createDirectorySafe :: FilePath -> IO Bool
createDirectorySafe fp = do
    curdir      <- getCurrentDirectory
    contents    <- getDirectoryContents curdir
    if fp `elem` contents
        then return False
        else True <$ createDirectory fp

removeDirContent :: DirContent -> IO ()
removeDirContent (File name)      = removeFile name
removeDirContent (Directory name) = removeDirectoryRecursive name

colonCommand :: NavimState -> String -> EventM n (Next NavimState)
colonCommand s input =
    case input of
        ":q" -> halt s
        -- TODO: other meta commands
        _ -> continue s { mode = Navigation }

inputCommand :: NavimState -> Prompt -> String -> EventM n (Next NavimState)
inputCommand s CreateFile name = do
    liftIO . writeFile name $ ""  -- TODO: use a safe variant (pls handle empty too)
    s' <- liftIO . buildState $ Just s
    continue s' { mode = Navigation }
inputCommand s CreateDirectory name = do
    success <- liftIO . createDirectorySafe $ name
    s' <- liftIO . buildState $ Just s
    continue s' { mode = Navigation }
inputCommand s Remove "y" = do
    liftIO . removeDirContent . nonEmptyCursorCurrent . navimStatePaths $ s
    s' <- liftIO . buildState $ Just s
    continue s' { mode = Navigation }
inputCommand s Remove _ = continue s { mode = Navigation }

{- END Event Handler Helpers -}
