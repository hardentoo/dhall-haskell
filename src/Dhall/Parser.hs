{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}

-- | This module contains Dhall's parsing logic

module Dhall.Parser (
    -- * Utilities
      exprFromText

    -- * Parsers
    , expr, exprA

    -- * Types
    , Src(..)
    , ParseError(..)
    , Parser(..)
    ) where

import Control.Applicative (Alternative(..), optional)
import Control.Exception (Exception)
import Control.Monad (MonadPlus)
import Data.ByteString (ByteString)
import Data.CharSet (CharSet)
import Data.Map (Map)
import Data.Monoid ((<>))
import Data.Sequence (ViewL(..))
import Data.Text.Buildable (Buildable(..))
import Data.Text.Lazy (Text)
import Data.Typeable (Typeable)
import Data.Vector (Vector)
import Dhall.Core
import Prelude hiding (const, pi)
import Text.PrettyPrint.ANSI.Leijen (Doc)
import Text.Parser.Combinators (choice, try, (<?>))
import Text.Parser.Token (IdentifierStyle(..), TokenParsing(..))
import Text.Parser.Token.Highlight (Highlight(..))
import Text.Trifecta
    (CharParsing, DeltaParsing, MarkParsing, Parsing, Result(..))
import Text.Trifecta.Delta (Delta)

import qualified Data.Char
import qualified Data.CharSet
import qualified Data.Map
import qualified Data.ByteString.Lazy
import qualified Data.List
import qualified Data.Sequence
import qualified Data.Text.Lazy
import qualified Data.Text.Lazy.Builder
import qualified Data.Text.Lazy.Encoding
import qualified Data.Vector
import qualified Filesystem.Path.CurrentOS
import qualified Text.Parser.Char
import qualified Text.Parser.Combinators
import qualified Text.Parser.Token
import qualified Text.Parser.Token.Style
import qualified Text.PrettyPrint.ANSI.Leijen
import qualified Text.Trifecta

-- | Source code extract
data Src = Src Delta Delta ByteString deriving (Eq, Show)

instance Buildable Src where
    build (Src begin _ bytes) =
            build text <> "\n"
        <>  "\n"
        <>  build (show (Text.PrettyPrint.ANSI.Leijen.pretty begin))
        <>  "\n"
      where
        bytes' = Data.ByteString.Lazy.fromStrict bytes

        text = Data.Text.Lazy.strip (Data.Text.Lazy.Encoding.decodeUtf8 bytes')

{-| A `Parser` that is almost identical to
    @"Text.Trifecta".`Text.Trifecta.Parser`@ except treating Haskell-style
    comments as whitespace
-}
newtype Parser a = Parser { unParser :: Text.Trifecta.Parser a }
    deriving
    (   Functor
    ,   Applicative
    ,   Monad
    ,   Alternative
    ,   MonadPlus
    ,   Parsing
    ,   CharParsing
    ,   DeltaParsing
    ,   MarkParsing Delta
    )

instance TokenParsing Parser where
    someSpace =
        Text.Parser.Token.Style.buildSomeSpaceParser
            (Parser someSpace)
            Text.Parser.Token.Style.haskellCommentStyle

    nesting (Parser m) = Parser (nesting m)

    semi = Parser semi

    highlight h (Parser m) = Parser (highlight h m)

identifierStyle :: IdentifierStyle Parser
identifierStyle = IdentifierStyle
    { _styleName     = "dhall"
    , _styleStart    =
        Text.Parser.Char.oneOf (['A'..'Z'] ++ ['a'..'z'] ++ "_")
    , _styleLetter   =
        Text.Parser.Char.oneOf (['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "_-/")
    , _styleReserved = reservedIdentifiers
    , _styleHighlight         = Identifier
    , _styleReservedHighlight = ReservedIdentifier
    }

noted :: Parser (Expr Src a) -> Parser (Expr Src a)
noted parser = do
    before     <- Text.Trifecta.position
    (e, bytes) <- Text.Trifecta.slicedWith (,) parser
    after      <- Text.Trifecta.position
    return (Note (Src before after bytes) e)

toMap :: [(Text, a)] -> Parser (Map Text a)
toMap kvs = do
    let adapt (k, v) = (k, pure v)
    let m = Data.Map.fromListWith (<|>) (fmap adapt kvs)
    let action k vs = case Data.Sequence.viewl vs of
            EmptyL  -> empty
            v :< vs' ->
                if null vs'
                then pure v
                else
                    Text.Parser.Combinators.unexpected
                        ("duplicate field: " ++ Data.Text.Lazy.unpack k)
    Data.Map.traverseWithKey action m

reserve :: String -> Parser ()
reserve string = do
    _ <- Text.Parser.Token.reserve identifierStyle string
    return ()

symbol :: String -> Parser ()
symbol string = do
    _ <- Text.Parser.Token.symbol string
    return ()

sepBy :: Parser a -> Parser b -> Parser [a]
sepBy p sep = sepBy1 p sep <|> pure []

sepBy1 :: Parser a -> Parser b -> Parser [a]
sepBy1 p sep = do
    a <- p
    b <- optional sep
    case b of
        Nothing -> return [a]
        Just _  -> do
            as <- sepBy p sep
            return (a:as)

stringLiteral :: Show a => Parser a -> Parser (Expr Src a)
stringLiteral embedded =
    Text.Parser.Token.token
        (   doubleQuoteLiteral embedded
        <|> doubleSingleQuoteString embedded
        )

doubleQuoteLiteral :: Show a => Parser a -> Parser (Expr Src a)
doubleQuoteLiteral embedded = do
    _  <- Text.Parser.Char.char '"'
    go
  where
    go = go0 <|> go1 <|> go2 <|> go3

    go0 = do
        _ <- Text.Parser.Char.char '"'
        return (TextLit mempty) 

    go1 = do
        _ <- Text.Parser.Char.text "${"
        Text.Parser.Token.whiteSpace
        a <- exprA embedded
        _ <- Text.Parser.Char.char '}'
        b <- go
        return (TextAppend a b)

    go2 = do
        _ <- Text.Parser.Char.text "''${"
        b <- go
        let e = case b of
                TextLit cs ->
                    TextLit ("${" <> cs)
                TextAppend (TextLit cs) d ->
                    TextAppend (TextLit ("${" <> cs)) d
                _ ->
                    TextAppend (TextLit "${") b
        return e

    go3 = do
        a <- stringChar
        b <- go
        let e = case b of
                TextLit cs ->
                    TextLit (build a <> cs)
                TextAppend (TextLit cs) d ->
                    TextAppend (TextLit (build a <> cs)) d
                _ ->
                    TextAppend (TextLit (build a)) b
        return e

doubleSingleQuoteString :: Show a => Parser a -> Parser (Expr Src a)
doubleSingleQuoteString embedded = do
    expr0 <- p0

    let builder0      = concatFragments expr0
    let text0         = Data.Text.Lazy.Builder.toLazyText builder0
    let lines0        = Data.Text.Lazy.lines text0
    let isEmpty       = Data.Text.Lazy.all Data.Char.isSpace
    let nonEmptyLines = filter (not . isEmpty) lines0

    let indentLength line =
            Data.Text.Lazy.length
                (Data.Text.Lazy.takeWhile Data.Char.isSpace line)

    let shortestIndent = case nonEmptyLines of
            [] -> 0
            _  -> minimum (map indentLength nonEmptyLines)

    -- The purpose of this complicated `trim0`/`trim1` is to ensure that we
    -- strip leading whitespace without stripping whitespace after variable
    -- interpolation
    let trim0 =
              build
            . Data.Text.Lazy.intercalate "\n"
            . map (Data.Text.Lazy.drop shortestIndent)
            . Data.Text.Lazy.splitOn "\n"
            . Data.Text.Lazy.Builder.toLazyText

    let trim1 builder = build (Data.Text.Lazy.intercalate "\n" lines_)
          where
            text = Data.Text.Lazy.Builder.toLazyText builder

            lines_ = case Data.Text.Lazy.splitOn "\n" text of
                []   -> []
                l:ls -> l:map (Data.Text.Lazy.drop shortestIndent) ls

    let process trim (TextAppend (TextLit t) e) =
            TextAppend (TextLit (trim t)) (process trim1 e)
        process _    (TextAppend e0 e1) =
            TextAppend e0 (process trim1 e1)
        process trim (TextLit t) =
            TextLit (trim t)
        process _     e =
            e

    return (process trim0 expr0)
  where
    -- This treats variable interpolation as breaking leading whitespace for the
    -- purposes of computing the shortest leading whitespace.  The "${VAR}"
    -- could really be any text that breaks whitespace
    concatFragments (TextAppend (TextLit t) e) = t        <> concatFragments e
    concatFragments (TextAppend  _          e) = "${VAR}" <> concatFragments e
    concatFragments (TextLit t)                = t
    concatFragments  _                         = mempty

    p0 = do
        _ <- Text.Parser.Char.string "''"
        p1

    p1 =    p2
        <|> p3
        <|> p4
        <|> p5 (Text.Parser.Char.char '\'')
        <|> p6
        <|> p5 Text.Parser.Char.anyChar

    p2 = do
        _  <- Text.Parser.Char.text "'''"
        s1 <- p1
        let s4 = case s1 of
                TextLit s2 ->
                    TextLit ("''" <> s2)
                TextAppend (TextLit s2) s3 ->
                    TextAppend (TextLit ("''" <> s2)) s3
                _ ->
                    TextAppend (TextLit "''") s1
        return s4

    p3 = do
        _  <- Text.Parser.Char.text "''${"
        s1 <- p1
        let s4 = case s1 of
                TextLit s2 ->
                    TextLit ("${" <> s2)
                TextAppend (TextLit s2) s3 ->
                    TextAppend (TextLit ("${" <> s2)) s3
                _ ->
                    TextAppend (TextLit "${") s1
        return s4

    p4 = do
        _ <- Text.Parser.Char.text "''"
        return (TextLit mempty)

    p5 parser = do
        s0 <- parser
        s1 <- p1
        let s4 = case s1 of
                TextLit s2 ->
                    TextLit (build s0 <> s2)
                TextAppend (TextLit s2) s3 ->
                    TextAppend (TextLit (build s0 <> s2)) s3
                _ -> TextAppend (TextLit (build s0)) s1
        return s4

    p6 = do
        _  <- Text.Parser.Char.text "${"
        Text.Parser.Token.whiteSpace
        s1 <- exprA embedded
        _  <- Text.Parser.Char.char '}'
        s3 <- p1
        return (TextAppend s1 s3)

stringChar :: Parser Char
stringChar =
        Text.Parser.Char.satisfy predicate
    <|> (do _ <- Text.Parser.Char.text "\\\\"; return '\\')
    <|> (do _ <- Text.Parser.Char.text "\\\""; return '"' )
    <|> (do _ <- Text.Parser.Char.text "\\n" ; return '\n')
    <|> (do _ <- Text.Parser.Char.text "\\r" ; return '\r')
    <|> (do _ <- Text.Parser.Char.text "\\t" ; return '\t')
  where
    predicate c = c /= '"' && c /= '\\' && c > '\026'

lambda :: Parser ()
lambda = symbol "\\" <|> symbol "λ"

pi :: Parser ()
pi = reserve "forall" <|> reserve "∀"

arrow :: Parser ()
arrow = symbol "->" <|> symbol "→"

combine :: Parser ()
combine = symbol "/\\" <|> symbol "∧"

prefer :: Parser ()
prefer = symbol "//" <|> symbol "⫽"

label :: Parser Text
label = (normalIdentifier <|> escapedIdentifier) <?> "label"
  where
    normalIdentifier = Text.Parser.Token.ident identifierStyle

    escapedIdentifier = Text.Parser.Token.token (do
        _  <- Text.Parser.Char.char '`'
        c  <- Text.Parser.Token._styleStart  identifierStyle
        cs <- many (Text.Parser.Token._styleLetter identifierStyle)
        _  <- Text.Parser.Char.char '`'
        return (Data.Text.Lazy.pack (c:cs)) )

-- | Parser for a top-level Dhall expression
expr :: Parser (Expr Src Path)
expr = exprA import_

-- | Parser for a top-level Dhall expression. The expression is parameterized
-- over any parseable type, allowing the language to be extended as needed.
exprA :: Show a => Parser a -> Parser (Expr Src a)
exprA embedded =
    (   noted
        (   choice
            [       exprA0
            ,       exprA1
            ,       exprA2
            ,       exprA3
            ,       exprA4
            ]
        )
    )   <|> exprA5
  where
    exprA0 = do
        lambda
        symbol "("
        a <- label
        symbol ":"
        b <- exprA embedded
        symbol ")"
        arrow
        c <- exprA embedded
        return (Lam a b c)

    exprA1 = do
        reserve "if"
        a <- exprA embedded
        reserve "then"
        b <- exprA embedded
        reserve "else"
        c <- exprA embedded
        return (BoolIf a b c)

    exprA2 = do
        pi
        symbol "("
        a <- label
        symbol ":"
        b <- exprA embedded
        symbol ")"
        arrow
        c <- exprA embedded
        return (Pi a b c)

    exprA3 = do
        reserve "let"
        a <- label
        b <- optional (do
            symbol ":"
            exprA embedded )
        symbol "="
        c <- exprA embedded
        reserve "in"
        d <- exprA embedded
        return (Let a b c d)

    exprA4 = do
        a <- try (exprC embedded <* arrow)
        b <- exprA embedded
        return (Pi "_" a b)

    exprA5 = exprB embedded

exprB :: Show a => Parser a -> Parser (Expr Src a)
exprB embedded =
    noted
    (   choice
        [       exprB0
        ,   try exprB1
        ,       exprB2
        ]
    )
  where
    exprB0 = do
        reserve "merge"
        a <- exprE embedded
        b <- exprE embedded
        c <- optional (do
            symbol ":"
            exprD embedded )
        return (Merge a b c)

    exprB1 = do
        symbol "["

        let emptyListOrOptional = do
                symbol "]"
                symbol ":"

                let emptyList = do
                        reserve "List"
                        a <- exprE embedded
                        return (ListLit (Just a) Data.Vector.empty)

                let emptyOptional = do
                        reserve "Optional"
                        a <- exprE embedded
                        return (OptionalLit a Data.Vector.empty)

                emptyList <|> emptyOptional

        let nonEmptyOptional = do
                a <- exprA embedded
                symbol "]"
                symbol ":"
                reserve "Optional"
                b <- exprE embedded
                return (OptionalLit b (Data.Vector.singleton a))

        emptyListOrOptional <|> nonEmptyOptional

    exprB2 = do
        a <- exprC embedded

        let exprB2A = do
                symbol ":"
                b <- exprA embedded
                return (Annot a b)

        let exprB2B = pure a

        exprB2A <|> exprB2B

exprC :: Show a => Parser a -> Parser (Expr Src a)
exprC embedded = exprC0
  where
    chain pA pOp op pB = noted (do
        a <- pA
        (do _ <- pOp <?> "operator"; b <- pB; return (op a b)) <|> pure a )

    exprC0 = chain  exprC1          (symbol "||") BoolOr       exprC0
    exprC1 = chain  exprC2          (symbol "+" ) NaturalPlus  exprC1
    exprC2 = chain  exprC3          (symbol "++") TextAppend   exprC2
    exprC3 = chain  exprC4          (symbol "#" ) ListAppend   exprC3
    exprC4 = chain  exprC5          (symbol "&&") BoolAnd      exprC4
    exprC5 = chain  exprC6           combine      Combine      exprC5
    exprC6 = chain  exprC7           prefer       Prefer       exprC6
    exprC7 = chain  exprC8          (symbol "*" ) NaturalTimes exprC7
    exprC8 = chain  exprC9          (symbol "==") BoolEQ       exprC8
    exprC9 = chain (exprD embedded) (symbol "!=") BoolNE       exprC9

-- We can't use left-recursion to define `exprD` otherwise the parser will
-- loop infinitely. However, I'd still like to use left-recursion in the
-- definition because left recursion greatly simplifies the use of `noted`.  The
-- work-around is to parse in two phases:
--
-- * First, parse to count how many arguments the function is applied to
-- * Second, restart the parse using left recursion bounded by the number of
--   arguments
exprD :: Show a => Parser a -> Parser (Expr Src a)
exprD embedded = do
    es <- some (noted (exprE embedded))
    let app nL@(Note (Src before _ bytesL) _) nR@(Note (Src _ after bytesR) _) =
            Note (Src before after (bytesL <> bytesR)) (App nL nR)
        app nL nR = App nL nR
    return (Data.List.foldl1 app es)

exprE :: Show a => Parser a -> Parser (Expr Src a)
exprE embedded = noted (do
    a <- exprF embedded

    let field = do
            symbol "."
            label

    b <- many field

    return (Data.List.foldl Field a b) )

exprF :: Show a => Parser a -> Parser (Expr Src a)
exprF embedded =
    noted
    (   choice
        [   try exprParseDouble
        ,   try exprNaturalLit
        ,   try exprIntegerLit
        ,       exprStringLiteral
        ,       exprRecordTypeOrLiteral
        ,       exprUnionTypeOrLiteral
        ,       exprListLiteral
        ,       exprImport
        ,   (choice
                [   exprNaturalFold
                ,   exprNaturalBuild
                ,   exprNaturalIsZero
                ,   exprNaturalEven
                ,   exprNaturalOdd
                ,   exprNaturalToInteger
                ,   exprNaturalShow
                ,   exprIntegerShow
                ,   exprDoubleShow
                ,   exprListBuild
                ,   exprListFold
                ,   exprListLength
                ,   exprListHead
                ,   exprListLast
                ,   exprListIndexed
                ,   exprListReverse
                ,   exprOptionalFold
                ,   exprOptionalBuild
                ,   exprBool
                ,   exprOptional
                ,   exprNatural
                ,   exprInteger
                ,   exprDouble
                ,   exprText
                ,   exprList
                ,   exprBoolLitTrue
                ,   exprBoolLitFalse
                ,   exprConst
                ]
            ) <?> "built-in value"
        ,       exprVar
        ]
    )   <|> exprParens
  where
    exprVar = do
        a <- var
        return (Var a)

    exprConst = do
        a <- const
        return (Const a)

    exprNatural = do
        reserve "Natural"
        return Natural

    exprNaturalFold = do
        reserve "Natural/fold"
        return NaturalFold

    exprNaturalBuild = do
        reserve "Natural/build"
        return NaturalBuild

    exprNaturalIsZero = do
        reserve "Natural/isZero"
        return NaturalIsZero

    exprNaturalEven = do
        reserve "Natural/even"
        return NaturalEven

    exprNaturalOdd = do
        reserve "Natural/odd"
        return NaturalOdd

    exprNaturalToInteger = do
        reserve "Natural/toInteger"
        return NaturalToInteger

    exprNaturalShow = do
        reserve "Natural/show"
        return NaturalShow

    exprInteger = do
        reserve "Integer"
        return Integer

    exprIntegerShow = do
        reserve "Integer/show"
        return IntegerShow

    exprDouble = do
        reserve "Double"
        return Double

    exprDoubleShow = do
        reserve "Double/show"
        return DoubleShow

    exprText = do
        reserve "Text"
        return Text

    exprList = do
        reserve "List"
        return List

    exprListBuild = do
        reserve "List/build"
        return ListBuild

    exprListFold = do
        reserve "List/fold"
        return ListFold

    exprListLength = do
        reserve "List/length"
        return ListLength

    exprListHead = do
        reserve "List/head"
        return ListHead

    exprListLast = do
        reserve "List/last"
        return ListLast

    exprListIndexed = do
        reserve "List/indexed"
        return ListIndexed

    exprListReverse = do
        reserve "List/reverse"
        return ListReverse

    exprOptional = do
        reserve "Optional"
        return Optional

    exprOptionalFold = do
        reserve "Optional/fold"
        return OptionalFold

    exprOptionalBuild = do
        reserve "Optional/build"
        return OptionalBuild

    exprBool = do
        reserve "Bool"
        return Bool

    exprBoolLitTrue = do
        reserve "True"
        return (BoolLit True)

    exprBoolLitFalse = do
        reserve "False"
        return (BoolLit False)

    exprIntegerLit = do
        a <- Text.Parser.Token.integer
        return (IntegerLit a)

    exprNaturalLit = (do
        _ <- Text.Parser.Char.char '+'
        a <- Text.Parser.Token.natural
        return (NaturalLit (fromIntegral a)) ) <?> "natural"

    exprParseDouble = do
        sign <-  fmap (\_ -> negate) (Text.Parser.Char.char '-')
             <|> fmap (\_ -> id    ) (Text.Parser.Char.char '+')
             <|> pure id
        a <- Text.Parser.Token.double
        return (DoubleLit (sign a))

    exprStringLiteral = stringLiteral embedded

    exprRecordTypeOrLiteral = recordTypeOrLiteral embedded <?> "record type or literal"

    exprUnionTypeOrLiteral = unionTypeOrLiteral embedded <?> "union type or literal"

    exprListLiteral = listLit embedded <?> "list literal"

    exprImport = do
        a <- embedded <?> "import"
        return (Embed a)

    exprParens = do
        symbol "("
        a <- exprA embedded
        symbol ")"
        return a

const :: Parser Const
const = const0
    <|> const1
  where
    const0 = do
        reserve "Type"
        return Type

    const1 = do
        reserve "Kind"
        return Kind

var :: Parser Var
var = do
    a <- label
    m <- optional (do
        symbol "@"
        Text.Parser.Token.natural )
    let b = case m of
            Just r  -> r
            Nothing -> 0
    return (V a b)

elems :: Show a => Parser a -> Parser (Vector (Expr Src a))
elems embedded = do
    a <- sepBy (exprA embedded) (symbol ",")
    return (Data.Vector.fromList a)

recordTypeOrLiteral :: Show a => Parser a -> Parser (Expr Src a)
recordTypeOrLiteral embedded = do
    symbol "{"

    let emptyRecordLiteral = do
            symbol "="
            symbol "}"
            return (RecordLit (Data.Map.fromList []))

    let emptyRecordType = do
            symbol "}"
            return (Record (Data.Map.fromList []))

    let nonEmptyRecordTypeOrLiteral = do
            a <- label

            let nonEmptyRecordLiteral = do
                    symbol "="
                    b <- exprA embedded

                    let recordLiteralWithoutOtherFields = do
                            symbol "}"
                            return (RecordLit (Data.Map.singleton a b))

                    let recordLiteralWithOtherFields = do
                            symbol ","
                            c <- fieldValues embedded
                            d <- toMap ((a, b):c)
                            symbol "}"
                            return (RecordLit d)

                    recordLiteralWithoutOtherFields <|> recordLiteralWithOtherFields

            let nonEmptyRecordType = do
                    symbol ":"
                    b <- exprA embedded

                    let recordTypeWithoutOtherFields = do
                            symbol "}"
                            return (Record (Data.Map.singleton a b))

                    let recordTypeWithOtherFields = do
                            symbol ","
                            c <- fieldTypes embedded
                            d <- toMap ((a, b):c)
                            symbol "}"
                            return (Record d)

                    recordTypeWithoutOtherFields <|> recordTypeWithOtherFields

            nonEmptyRecordLiteral <|> nonEmptyRecordType

    emptyRecordLiteral <|> emptyRecordType <|> nonEmptyRecordTypeOrLiteral

fieldValues :: Show a => Parser a -> Parser [(Text, Expr Src a)]
fieldValues embedded = sepBy1 (fieldValue embedded) (symbol ",")

fieldValue :: Show a => Parser a -> Parser (Text, Expr Src a)
fieldValue embedded = do
    a <- label
    symbol "="
    b <- exprA embedded
    return (a, b)

fieldTypes :: Show a => Parser a -> Parser [(Text, Expr Src a)]
fieldTypes embedded = sepBy (fieldType embedded) (symbol ",")

fieldType :: Show a => Parser a -> Parser (Text, Expr Src a)
fieldType embedded = do
    a <- label
    symbol ":"
    b <- exprA embedded
    return (a, b)

unionTypeOrLiteral :: Show a => Parser a -> Parser (Expr Src a)
unionTypeOrLiteral embedded = do
    symbol "<"

    let emptyUnionTypeOrLiteral = do
            symbol ">"
            return (Union Data.Map.empty)

    let nonEmptyUnionTypeOrLiteral = do
            a <- label

            let unionType = do
                    symbol ":"
                    b <- exprA embedded

                    let unionTypeWithoutAlternatives = do
                            symbol ">"
                            return (Union (Data.Map.singleton a b))

                    let unionTypeWithAlternatives = do
                            symbol "|"
                            c <- alternativeTypes embedded
                            symbol ">"
                            d <- toMap ((a, b):c)
                            return (Union d)

                    unionTypeWithoutAlternatives <|> unionTypeWithAlternatives

            let unionLiteral = do
                    symbol "="
                    b <- exprA embedded
                    let unionLitWithoutAlternatives = do
                            symbol ">"
                            return (UnionLit a b Data.Map.empty)

                    let unionLitWithAlternatives = do
                            symbol "|"
                            c <- alternativeTypes embedded
                            d <- toMap c
                            symbol ">"
                            return (UnionLit a b d)
                    unionLitWithoutAlternatives <|> unionLitWithAlternatives

            unionType <|> unionLiteral

    emptyUnionTypeOrLiteral <|> nonEmptyUnionTypeOrLiteral

alternativeTypes :: Show a => Parser a -> Parser [(Text, Expr Src a)]
alternativeTypes embedded = sepBy (alternativeType embedded) (symbol "|")

alternativeType :: Show a => Parser a -> Parser (Text, Expr Src a)
alternativeType embedded = do
    a <- label
    symbol ":"
    b <- exprA embedded
    return (a, b)

listLit :: Show a => Parser a -> Parser (Expr Src a)
listLit embedded = do
    symbol "["
    a <- elems embedded
    symbol "]"
    return (ListLit Nothing a)

import_ :: Parser Path
import_ = do
    pathType <- pathType_
    let rawText = do
            _ <- reserve "as"
            _ <- reserve "Text"
            return RawText
    pathMode <- rawText <|> pure Code
    return (Path {..})

pathType_ :: Parser PathType
pathType_ = file <|> url <|> env

pathChar :: Char -> Bool
pathChar c =
    not
    (   Data.Char.isSpace c
    ||  Data.CharSet.member c disallowedPathChars
    )

disallowedPathChars :: CharSet
disallowedPathChars = Data.CharSet.fromList "()[]{}<>"

file :: Parser PathType
file =  try (token file0)
    <|>      token file1
    <|>      token file2
    <|>      token file3
  where
    file0 = do
        a <- Text.Parser.Char.string "/"
        b <- many (Text.Parser.Char.satisfy pathChar)
        case b of
            '\\':_ -> empty -- So that "/\" parses as the operator and not a path
            '/' :_ -> empty -- So that "//" parses as the operator and not a path
            _      -> return ()
        Text.Parser.Token.whiteSpace
        return (File Homeless (Filesystem.Path.CurrentOS.decodeString (a <> b)))

    file1 = do
        a <- Text.Parser.Char.string "./"
        b <- many (Text.Parser.Char.satisfy pathChar)
        Text.Parser.Token.whiteSpace
        return (File Homeless (Filesystem.Path.CurrentOS.decodeString (a <> b)))

    file2 = do
        a <- Text.Parser.Char.string "../"
        b <- many (Text.Parser.Char.satisfy pathChar)
        Text.Parser.Token.whiteSpace
        return (File Homeless (Filesystem.Path.CurrentOS.decodeString (a <> b)))

    file3 = do
        _ <- Text.Parser.Char.string "~"
        _ <- some (Text.Parser.Char.string "/")
        b <- many (Text.Parser.Char.satisfy pathChar)
        Text.Parser.Token.whiteSpace
        return (File Home (Filesystem.Path.CurrentOS.decodeString b))

url :: Parser PathType
url =   try url0
    <|> url1
  where
    url0 = do
        a <- Text.Parser.Char.string "https://"
        b <- many (Text.Parser.Char.satisfy pathChar)
        Text.Parser.Token.whiteSpace
        c <- optional (do
            _ <- Text.Parser.Char.string "using"
            Text.Parser.Token.whiteSpace
            pathType_ )
        return (URL (Data.Text.Lazy.pack (a <> b)) c)

    url1 = do
        a <- Text.Parser.Char.string "http://"
        b <- many (Text.Parser.Char.satisfy pathChar)
        Text.Parser.Token.whiteSpace
        c <- optional (do
            _ <- Text.Parser.Char.string "using"
            Text.Parser.Token.whiteSpace
            pathType_ )
        return (URL (Data.Text.Lazy.pack (a <> b)) c)

env :: Parser PathType
env = do
    _ <- Text.Parser.Char.string "env:"
    a <- many (Text.Parser.Char.satisfy pathChar)
    Text.Parser.Token.whiteSpace
    return (Env (Data.Text.Lazy.pack a))

-- | A parsing error
newtype ParseError = ParseError Doc deriving (Typeable)

instance Show ParseError where
    show (ParseError doc) =
      "\n\ESC[1;31mError\ESC[0m: Invalid input\n\n" <> show doc

instance Exception ParseError

-- | Parse an expression from `Text` containing a Dhall program
exprFromText :: Delta -> Text -> Either ParseError (Expr Src Path)
exprFromText delta text = case result of
    Success r       -> Right r
    Failure errInfo -> Left (ParseError (Text.Trifecta._errDoc errInfo))
  where
    string = Data.Text.Lazy.unpack text

    parser = unParser (do
        Text.Parser.Token.whiteSpace
        r <- expr
        Text.Parser.Combinators.eof
        return r )

    result = Text.Trifecta.parseString parser delta string
