{-# LANGUAGE AutoDeriveTypeable  #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DefaultSignatures   #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

#include "version-compatibility-macros.h"

-- | __Warning: internal module!__ This means that the API may change
-- arbitrarily between versions without notice. Depending on this module may
-- lead to unexpected breakages, so proceed with caution!
--
-- For a stable API, use the non-internal modules. For the special case of
-- writing adaptors to this library’s @'Doc'@ type, see
-- "Data.Text.Prettyprint.Doc.Internal.Type".
module Data.Text.Prettyprint.Doc.Internal (
    module Data.Text.Prettyprint.Doc.Internal
) where



import           Control.Applicative
import           Data.Int
import           Data.List.NonEmpty  (NonEmpty (..))
import           Data.Maybe
import           Data.String         (IsString (..))
import           Data.Text           (Text)
import qualified Data.Text           as T
import qualified Data.Text.Lazy      as Lazy
import           Data.Void
import           Data.Word
import           GHC.Generics        (Generic)

-- Depending on the Cabal file, this might be from base, or for older builds,
-- from the semigroups package.
import Data.Semigroup

#if NATURAL_IN_BASE
import Numeric.Natural
#endif

#if !(FOLDABLE_TRAVERSABLE_IN_PRELUDE)
import Data.Foldable    (Foldable (..))
import Data.Traversable (Traversable (..))
import Prelude          hiding (foldr, foldr1)
#endif

#if !(MONOID_IN_PRELUDE)
import Data.Monoid hiding ((<>))
#endif

import Data.Text.Prettyprint.Doc.Render.Util.Panic



-- | The abstract data type @'Doc' ann@ represents pretty documents that have
-- been annotated with data of type @ann@.
--
-- More specifically, a value of type @'Doc'@ represents a non-empty set of
-- possible layouts of a document. The layout functions select one of these
-- possibilities, taking into account things like the width of the output
-- document.
--
-- The annotation is an arbitrary piece of data associated with (part of) a
-- document. Annotations may be used by the rendering backends in order to
-- display output differently, such as
--
--   - color information (e.g. when rendering to the terminal)
--   - mouseover text (e.g. when rendering to rich HTML)
--   - whether to show something or not (to allow simple or detailed versions)
--
-- The simplest way to display a 'Doc' is via the 'Show' class.
--
-- >>> putStrLn (show (vsep ["hello", "world"]))
-- hello
-- world
data Doc ann =

    -- | Occurs when flattening a line. The layouter will reject this document,
    -- choosing a more suitable rendering.
    Fail

    -- | The empty document; conceptually the unit of 'Cat'
    | Empty

    -- | invariant: not '\n'
    | Char !Char

    -- | Invariants: at least two characters long, does not contain '\n'. For
    -- empty documents, there is @Empty@; for singleton documents, there is
    -- @Char@; newlines should be replaced by e.g. @Line@.
    --
    -- Since the frequently used 'T.length' of 'Text' is /O(length)/, we cache
    -- it in this constructor.
    | Text !Int !Text

    -- | Hard line break
    | Line

    -- | Lay out the first 'Doc', but when flattened (via 'group'), fall back to
    -- the second. The flattened version should in general be higher and
    -- narrower than the fallback.
    | FlatAlt (Doc ann) (Doc ann)

    -- | Concatenation of two documents
    | Cat (Doc ann) (Doc ann)

    -- | Document indented by a number of columns
    | Nest !Int (Doc ann)

    -- | Invariant: The first lines of first document should be longer than the
    -- first lines of the second one, so the layout algorithm can pick the one
    -- that fits best. Used to implement layout alternatives for 'group'.
    | Union (Doc ann) (Doc ann)

    -- | React on the current cursor position, see 'column'
    | Column (Int -> Doc ann)

    -- | React on the document's width, see 'pageWidth'
    | WithPageWidth (PageWidth -> Doc ann)

    -- | React on the current nesting level, see 'nesting'
    | Nesting (Int -> Doc ann)

    -- | Add an annotation to the enclosed 'Doc'. Can be used for example to add
    -- styling directives or alt texts that can then be used by the renderer.
    | Annotated ann (Doc ann)
    deriving (Generic)

-- |
-- @
-- x '<>' y = 'hcat' [x, y]
-- @
--
-- >>> "hello" <> "world" :: Doc ann
-- helloworld
instance Semigroup (Doc ann) where
    (<>) = Cat
    sconcat (x :| xs) = hcat (x:xs)

-- |
-- @
-- 'mempty' = 'emptyDoc'
-- 'mconcat' = 'hcat'
-- @
--
-- >>> mappend "hello" "world" :: Doc ann
-- helloworld
instance Monoid (Doc ann) where
    mempty = emptyDoc
    mappend = (<>)
    mconcat = hcat

-- | >>> pretty ("hello\nworld")
-- hello
-- world
--
-- This instance uses the 'Pretty' 'Text' instance, and uses the same newline to
-- 'line' conversion.
instance IsString (Doc ann) where
    fromString = pretty . T.pack

-- | Alter the document’s annotations.
--
-- This instance makes 'Doc' more flexible (because it can be used in
-- 'Functor'-polymorphic values), but @'fmap'@ is much less readable compared to
-- using @'reAnnotate'@ in code that only works for @'Doc'@ anyway. Consider
-- using the latter when the type does not matter.
instance Functor Doc where
    fmap = reAnnotate

-- | Overloaded conversion to 'Doc'.
--
-- Laws:
--
--   1. output should be pretty. :-)
class Pretty a where

    -- | >>> pretty 1 <+> pretty "hello" <+> pretty 1.234
    -- 1 hello 1.234
    pretty :: a -> Doc ann

    default pretty :: Show a => a -> Doc ann
    pretty = viaShow

    -- | @'prettyList'@ is only used to define the @instance
    -- 'Pretty' a => 'Pretty' [a]@. In normal circumstances only the @'pretty'@
    -- function is used.
    --
    -- >>> prettyList [1, 23, 456]
    -- [1, 23, 456]
    prettyList :: [a] -> Doc ann
    prettyList = list . map pretty

-- | >>> pretty [1,2,3]
-- [1, 2, 3]
instance Pretty a => Pretty [a] where
    pretty = prettyList

instance Pretty a => Pretty (NonEmpty a) where
    pretty (x:|xs) = prettyList (x:xs)

-- | Does not change the text, but removes all annotations. __Pitfall__: since
-- this un-annotates its argument, nesting it means multiple, potentially
-- costly, traversals over the 'Doc'.
--
-- >>> pretty 123
-- 123
-- >>> pretty (pretty 123)
-- 123
instance Pretty (Doc ann) where
    pretty = unAnnotate

-- | >>> pretty ()
-- ()
--
-- The argument is not used,
--
-- >>> pretty (error "Strict?" :: ())
-- ()
instance Pretty () where
    pretty _ = "()"

-- | >>> pretty True
-- True
instance Pretty Bool where
    pretty = \case
        True  -> "True"
        False -> "False"

-- | Instead of @('pretty' '\n')@, consider using @'line'@ as a more readable
-- alternative.
--
-- >>> pretty 'f' <> pretty 'o' <> pretty 'o'
-- foo
-- >>> pretty ("string" :: String)
-- string
instance Pretty Char where
    pretty '\n' = line
    pretty c = Char c

    prettyList = pretty . (id :: Text -> Text) . fromString

-- | Convert a 'Show'able value to a 'Doc'. If the 'String' does not contain
-- newlines, consider using the more performant 'unsafeViaShow'.
viaShow :: Show a => a -> Doc ann
viaShow = pretty . T.pack . show

-- | Convert a 'Show'able value /that must not contain newlines/ to a 'Doc'.
-- If there may be newlines, use 'viaShow' instead.
unsafeViaShow :: Show a => a -> Doc ann
unsafeViaShow = unsafeTextWithoutNewlines . T.pack . show

-- | >>> pretty (123 :: Int)
-- 123
instance Pretty Int    where pretty = unsafeViaShow
instance Pretty Int8   where pretty = unsafeViaShow
instance Pretty Int16  where pretty = unsafeViaShow
instance Pretty Int32  where pretty = unsafeViaShow
instance Pretty Int64  where pretty = unsafeViaShow
instance Pretty Word   where pretty = unsafeViaShow
instance Pretty Word8  where pretty = unsafeViaShow
instance Pretty Word16 where pretty = unsafeViaShow
instance Pretty Word32 where pretty = unsafeViaShow
instance Pretty Word64 where pretty = unsafeViaShow

-- | >>> pretty (2^123 :: Integer)
-- 10633823966279326983230456482242756608
instance Pretty Integer where pretty = unsafeViaShow

#if NATURAL_IN_BASE
instance Pretty Natural where pretty = unsafeViaShow
#endif

-- | >>> pretty (pi :: Float)
-- 3.1415927
instance Pretty Float where pretty = unsafeViaShow

-- | >>> pretty (exp 1 :: Double)
-- 2.718281828459045
instance Pretty Double where pretty = unsafeViaShow

-- | >>> pretty (123, "hello")
-- (123, hello)
instance (Pretty a1, Pretty a2) => Pretty (a1,a2) where
    pretty (x1,x2) = tupled [pretty x1, pretty x2]

-- | >>> pretty (123, "hello", False)
-- (123, hello, False)
instance (Pretty a1, Pretty a2, Pretty a3) => Pretty (a1,a2,a3) where
    pretty (x1,x2,x3) = tupled [pretty x1, pretty x2, pretty x3]

--    -- | >>> pretty (123, "hello", False, ())
--    -- (123, hello, False, ())
--    instance (Pretty a1, Pretty a2, Pretty a3, Pretty a4) => Pretty (a1,a2,a3,a4) where
--        pretty (x1,x2,x3,x4) = tupled [pretty x1, pretty x2, pretty x3, pretty x4]
--
--    -- | >>> pretty (123, "hello", False, (), 3.14)
--    -- (123, hello, False, (), 3.14)
--    instance (Pretty a1, Pretty a2, Pretty a3, Pretty a4, Pretty a5) => Pretty (a1,a2,a3,a4,a5) where
--        pretty (x1,x2,x3,x4,x5) = tupled [pretty x1, pretty x2, pretty x3, pretty x4, pretty x5]
--
--    -- | >>> pretty (123, "hello", False, (), 3.14, Just 2.71)
--    -- ( 123
--    -- , hello
--    -- , False
--    -- , ()
--    -- , 3.14
--    -- , 2.71 )
--    instance (Pretty a1, Pretty a2, Pretty a3, Pretty a4, Pretty a5, Pretty a6) => Pretty (a1,a2,a3,a4,a5,a6) where
--        pretty (x1,x2,x3,x4,x5,x6) = tupled [pretty x1, pretty x2, pretty x3, pretty x4, pretty x5, pretty x6]
--
--    -- | >>> pretty (123, "hello", False, (), 3.14, Just 2.71, [1,2,3])
--    -- ( 123
--    -- , hello
--    -- , False
--    -- , ()
--    -- , 3.14
--    -- , 2.71
--    -- , [1, 2, 3] )
--    instance (Pretty a1, Pretty a2, Pretty a3, Pretty a4, Pretty a5, Pretty a6, Pretty a7) => Pretty (a1,a2,a3,a4,a5,a6,a7) where
--        pretty (x1,x2,x3,x4,x5,x6,x7) = tupled [pretty x1, pretty x2, pretty x3, pretty x4, pretty x5, pretty x6, pretty x7]

-- | Ignore 'Nothing's, print 'Just' contents.
--
-- >>> pretty (Just True)
-- True
-- >>> braces (pretty (Nothing :: Maybe Bool))
-- {}
--
-- >>> pretty [Just 1, Nothing, Just 3, Nothing]
-- [1, 3]
instance Pretty a => Pretty (Maybe a) where
    pretty = maybe mempty pretty
    prettyList = prettyList . catMaybes

-- | Automatically converts all newlines to @'line'@.
--
-- >>> pretty ("hello\nworld" :: Text)
-- hello
-- world
--
-- Note that  @'line'@ can be undone by @'group'@:
--
-- >>> group (pretty ("hello\nworld" :: Text))
-- hello world
--
-- Manually use @'hardline'@ if you /definitely/ want newlines.
instance Pretty Text where pretty = vsep . map unsafeTextWithoutNewlines . T.splitOn "\n"

-- | (lazy 'Text' instance, identical to the strict version)
instance Pretty Lazy.Text where pretty = pretty . Lazy.toStrict

-- | Finding a good example for printing something that does not exist is hard,
-- so here is an example of printing a list full of nothing.
--
-- >>> pretty ([] :: [Void])
-- []
instance Pretty Void where pretty = absurd



-- | @(unsafeTextWithoutNewlines s)@ contains the literal string @s@.
--
-- The string must not contain any newline characters, since this is an
-- invariant of the 'Text' constructor.
unsafeTextWithoutNewlines :: Text -> Doc ann
unsafeTextWithoutNewlines text = case T.uncons text of
    Nothing -> Empty
    Just (t,ext)
        | T.null ext -> Char t
        | otherwise -> Text (T.length text) text

-- | The empty document behaves like @('pretty' "")@, so it has a height of 1.
-- This may lead to surprising behaviour if we expect it to bear no weight
-- inside e.g. 'vcat', where we get an empty line of output from it ('parens'
-- for visibility only):
--
-- >>> vsep ["hello", parens emptyDoc, "world"]
-- hello
-- ()
-- world
--
-- Together with '<>', 'emptyDoc' forms the 'Monoid' 'Doc'.
emptyDoc :: Doc ann
emptyDoc = Empty

-- | @('nest' i x)@ lays out the document @x@ with the current indentation level
-- increased by @i@. Negative values are allowed, and decrease the nesting level
-- accordingly.
--
-- >>> vsep [nest 4 (vsep ["lorem", "ipsum", "dolor"]), "sit", "amet"]
-- lorem
--     ipsum
--     dolor
-- sit
-- amet
--
-- See also 'hang', 'align' and 'indent'.
nest
    :: Int -- ^ Change of nesting level
    -> Doc ann
    -> Doc ann
nest 0 x = x -- Optimization
nest i x = Nest i x

-- | The @'line'@ document advances to the next line and indents to the current
-- nesting level.
--
-- >>> let doc = "lorem ipsum" <> line <> "dolor sit amet"
-- >>> doc
-- lorem ipsum
-- dolor sit amet
--
-- @'line'@ behaves like @'space'@ if the line break is undone by 'group':
--
-- >>> group doc
-- lorem ipsum dolor sit amet
line :: Doc ann
line = FlatAlt Line space

-- | @'line''@ is like @'line'@, but behaves like @'mempty'@ if the line break
-- is undone by 'group' (instead of @'space'@).
--
-- >>> let doc = "lorem ipsum" <> line' <> "dolor sit amet"
-- >>> doc
-- lorem ipsum
-- dolor sit amet
-- >>> group doc
-- lorem ipsumdolor sit amet
line' :: Doc ann
line' = FlatAlt Line mempty

-- | @softline@ behaves like @'space'@ if the resulting output fits the page,
-- otherwise like @'line'@.
--
-- Here, we have enough space to put everything in one line:
--
-- >>> let doc = "lorem ipsum" <> softline <> "dolor sit amet"
-- >>> putDocW 80 doc
-- lorem ipsum dolor sit amet
--
-- If we narrow the page to width 10, the layouter produces a line break:
--
-- >>> putDocW 10 doc
-- lorem ipsum
-- dolor sit amet
--
-- @
-- 'softline' = 'group' 'line'
-- @
softline :: Doc ann
softline = group line

-- | @'softline''@ is like @'softline'@, but behaves like @'mempty'@ if the
-- resulting output does not fit on the page (instead of @'space'@). In other
-- words, @'line'@ is to @'line''@ how @'softline'@ is to @'softline''@.
--
-- With enough space, we get direct concatenation:
--
-- >>> let doc = "ThisWord" <> softline' <> "IsWayTooLong"
-- >>> putDocW 80 doc
-- ThisWordIsWayTooLong
--
-- If we narrow the page to width 10, the layouter produces a line break:
--
-- >>> putDocW 10 doc
-- ThisWord
-- IsWayTooLong
--
-- @
-- 'softline'' = 'group' 'line''
-- @
softline' :: Doc ann
softline' = group line'

-- | A @'hardline'@ is /always/ laid out as a line break, even when 'group'ed or
-- when there is plenty of space. Note that it might still be simply discarded
-- if it is part of a 'flatAlt' inside a 'group'.
--
-- >>> let doc = "lorem ipsum" <> hardline <> "dolor sit amet"
-- >>> putDocW 1000 doc
-- lorem ipsum
-- dolor sit amet
--
-- >>> group doc
-- lorem ipsum
-- dolor sit amet
hardline :: Doc ann
hardline = Line

-- | @('group' x)@ tries laying out @x@ into a single line by removing the
-- contained line breaks; if this does not fit the page, @x@ is laid out without
-- any changes. The 'group' function is key to layouts that adapt to available
-- space nicely.
--
-- See 'vcat', 'line', or 'flatAlt' for examples that are related, or make good
-- use of it.
group :: Doc ann -> Doc ann
-- See note [Group: special flattening]
group x = case changesUponFlattening x of
    Nothing -> x
    Just x' -> Union x' x

-- Note [Group: special flattening]
--
-- Since certain documents do not change under removal of newlines etc, there is
-- no point in creating a 'Union' of the flattened and unflattened version – all
-- this does is introducing two branches for the layout algorithm to take,
-- resulting in potentially exponential behavior on deeply nested examples, such
-- as
--
--     pathological n = iterate (\x ->  hsep [x, sep []] ) "foobar" !! n
--
-- See https://github.com/quchen/prettyprinter/issues/22 for the  corresponding
-- ticket.

-- | Choose the first element of each @Union@, and discard the first field of
-- all @FlatAlt@s.
--
-- The result is 'Just' if the element might change depending on the layout
-- algorithm (i.e. contains differently renderable sub-documents), and 'Nothing'
-- if the document is static (e.g. contains only a plain 'Empty' node). See
-- [Group: special flattening] for further explanations.
changesUponFlattening :: Doc ann -> Maybe (Doc ann)
changesUponFlattening = \case
    FlatAlt _ y     -> Just (flatten y)
    Line            -> Just Fail
    Union x _       -> changesUponFlattening x <|> Just x
    Nest i x        -> fmap (Nest i) (changesUponFlattening x)
    Annotated ann x -> fmap (Annotated ann) (changesUponFlattening x)

    Column f        -> Just (Column (flatten . f))
    Nesting f       -> Just (Nesting (flatten . f))
    WithPageWidth f -> Just (WithPageWidth (flatten . f))

    Cat x y -> case (changesUponFlattening x, changesUponFlattening y) of
        (Nothing, Nothing) -> Nothing
        (Just x', Nothing) -> Just (Cat x' y )
        (Nothing, Just y') -> Just (Cat x  y')
        (Just x', Just y') -> Just (Cat x' y')

    Empty  -> Nothing
    Char{} -> Nothing
    Text{} -> Nothing
    Fail   -> Nothing
  where
    -- Flatten, but don’t report whether anything changes.
    flatten :: Doc ann -> Doc ann
    flatten = \case
        FlatAlt _ y     -> flatten y
        Cat x y         -> Cat (flatten x) (flatten y)
        Nest i x        -> Nest i (flatten x)
        Line            -> Fail
        Union x _       -> flatten x
        Column f        -> Column (flatten . f)
        WithPageWidth f -> WithPageWidth (flatten . f)
        Nesting f       -> Nesting (flatten . f)
        Annotated ann x -> Annotated ann (flatten x)

        x@Fail   -> x
        x@Empty  -> x
        x@Char{} -> x
        x@Text{} -> x



-- | @('flatAlt' x fallback)@ renders as @x@ by default, but falls back to
-- @fallback@ when 'group'ed. Since the layout algorithms rely on 'group' having
-- an effect of shortening the width of the contained text, careless usage of
-- 'flatAlt' with wide fallbacks might lead to unappealingly long lines.
--
-- 'flatAlt' is particularly useful for defining conditional separators such as
--
-- @
-- softHyphen = 'flatAlt' 'mempty' "-"
-- softline   = 'flatAlt' 'space' 'line'
-- @
--
-- We can use this to render Haskell's do-notation nicely:
--
-- >>> let open        = flatAlt "" "{ "
-- >>> let close       = flatAlt "" " }"
-- >>> let separator   = flatAlt "" "; "
-- >>> let prettyDo xs = group ("do" <+> encloseSep open close separator xs)
-- >>> let statements  = ["name:_ <- getArgs", "let greet = \"Hello, \" <> name", "putStrLn greet"]
--
-- This is put into a single line with @{;}@ style if it fits,
--
-- >>> putDocW 80 (prettyDo statements)
-- do { name:_ <- getArgs; let greet = "Hello, " <> name; putStrLn greet }
--
-- When there is not enough space the statements are broken up into lines
-- nicely,
--
-- >>> putDocW 10 (prettyDo statements)
-- do name:_ <- getArgs
--    let greet = "Hello, " <> name
--    putStrLn greet
flatAlt
    :: Doc ann -- ^ Default
    -> Doc ann -- ^ Fallback when 'group'ed
    -> Doc ann
flatAlt = FlatAlt



-- | @('align' x)@ lays out the document @x@ with the nesting level set to the
-- current column. It is used for example to implement 'hang'.
--
-- As an example, we will put a document right above another one, regardless of
-- the current nesting level. Without 'align'ment, the second line is put simply
-- below everything we've had so far,
--
-- >>> "lorem" <+> vsep ["ipsum", "dolor"]
-- lorem ipsum
-- dolor
--
-- If we add an 'align' to the mix, the @'vsep'@'s contents all start in the
-- same column,
--
-- >>> "lorem" <+> align (vsep ["ipsum", "dolor"])
-- lorem ipsum
--       dolor
align :: Doc ann -> Doc ann
align d = column (\k -> nesting (\i -> nest (k - i) d)) -- nesting might be negative!

-- | @('hang' i x)@ lays out the document @x@ with a nesting level set to the
-- /current column/ plus @i@. Negative values are allowed, and decrease the
-- nesting level accordingly.
--
-- >>> let doc = reflow "Indenting these words with hang"
-- >>> putDocW 24 ("prefix" <+> hang 4 doc)
-- prefix Indenting these
--            words with
--            hang
--
-- This differs from 'nest', which is based on the /current nesting level/ plus
-- @i@. When you're not sure, try the more efficient 'nest' first. In our
-- example, this would yield
--
-- >>> let doc = reflow "Indenting these words with nest"
-- >>> putDocW 24 ("prefix" <+> nest 4 doc)
-- prefix Indenting these
--     words with nest
--
-- @
-- 'hang' i doc = 'align' ('nest' i doc)
-- @
hang
    :: Int -- ^ Change of nesting level, relative to the start of the first line
    -> Doc ann
    -> Doc ann
hang i d = align (nest i d)

-- | @('indent' i x)@ indents document @x@ with @i@ spaces, starting from the
-- current cursor position.
--
-- >>> let doc = reflow "The indent function indents these words!"
-- >>> putDocW 24 ("prefix" <> indent 4 doc)
-- prefix    The indent
--           function
--           indents these
--           words!
--
-- @
-- 'indent' i d = 'hang' i ({i spaces} <> d)
-- @
indent
    :: Int -- ^ Number of spaces to increase indentation by
    -> Doc ann
    -> Doc ann
indent i d = hang i (spaces i <> d)

-- | @('encloseSep' l r sep xs)@ concatenates the documents @xs@ separated by
-- @sep@, and encloses the resulting document by @l@ and @r@.
--
-- The documents are laid out horizontally if that fits the page,
--
-- >>> let doc = "list" <+> encloseSep lbracket rbracket comma (map pretty [1,20,300,4000])
-- >>> putDocW 80 doc
-- list [1,20,300,4000]
--
-- If there is not enough space, then the input is split into lines entry-wise
-- therwise they are aligned vertically, with separators put in the front:
--
-- >>> putDocW 10 doc
-- list [1
--      ,20
--      ,300
--      ,4000]
--
-- For putting separators at the end of entries instead, have a look at
-- 'punctuate'.
encloseSep
    :: Doc ann   -- ^ left delimiter
    -> Doc ann   -- ^ right delimiter
    -> Doc ann   -- ^ separator
    -> [Doc ann] -- ^ input documents
    -> Doc ann
encloseSep l r s ds = case ds of
    []  -> l <> r
    [d] -> l <> d <> r
    _   -> align (cat (zipWith (<>) (l : repeat s) ds) <> r)

-- | Haskell-inspired variant of 'encloseSep' with braces and comma as
-- separator.
--
-- >>> let doc = list (map pretty [1,20,300,4000])
--
-- >>> putDocW 80 doc
-- [1, 20, 300, 4000]
--
-- >>> putDocW 10 doc
-- [ 1
-- , 20
-- , 300
-- , 4000 ]
list :: [Doc ann] -> Doc ann
list = group . encloseSep (flatAlt "[ " "[")
                          (flatAlt " ]" "]")
                          ", "

-- | Haskell-inspired variant of 'encloseSep' with parentheses and comma as
-- separator.
--
-- >>> let doc = tupled (map pretty [1,20,300,4000])
--
-- >>> putDocW 80 doc
-- (1, 20, 300, 4000)
--
-- >>> putDocW 10 doc
-- ( 1
-- , 20
-- , 300
-- , 4000 )
tupled :: [Doc ann] -> Doc ann
tupled = group . encloseSep (flatAlt "( " "(")
                            (flatAlt " )" ")")
                            ", "



-- | @(x '<+>' y)@ concatenates document @x@ and @y@ with a @'space'@ in
-- between.
--
-- >>> "hello" <+> "world"
-- hello world
--
-- @
-- x '<+>' y = x '<>' 'space' '<>' y
-- @
(<+>) :: Doc ann -> Doc ann -> Doc ann
x <+> y = x <> space <> y



-- | Concatenate all documents element-wise with a binary function.
--
-- @
-- 'concatWith' _ [] = 'mempty'
-- 'concatWith' (**) [x,y,z] = x ** y ** z
-- @
--
-- Multiple convenience definitions based on 'concatWith' are alredy predefined,
-- for example
--
-- @
-- 'hsep'    = 'concatWith' ('<+>')
-- 'fillSep' = 'concatWith' (\\x y -> x '<>' 'softline' '<>' y)
-- @
--
-- This is also useful to define customized joiners,
--
-- >>> concatWith (surround dot) ["Data", "Text", "Prettyprint", "Doc"]
-- Data.Text.Prettyprint.Doc
concatWith :: Foldable t => (Doc ann -> Doc ann -> Doc ann) -> t (Doc ann) -> Doc ann
concatWith f ds
#if !(FOLDABLE_TRAVERSABLE_IN_PRELUDE)
    | foldr (\_ _ -> False) True ds = mempty
#else
    | null ds = mempty
#endif
    | otherwise = foldr1 f ds
{-# INLINE concatWith #-}

-- | @('hsep' xs)@ concatenates all documents @xs@ horizontally with @'<+>'@,
-- i.e. it puts a space between all entries.
--
-- >>> let docs = Util.words "lorem ipsum dolor sit amet"
--
-- >>> hsep docs
-- lorem ipsum dolor sit amet
--
-- @'hsep'@ does not introduce line breaks on its own, even when the page is too
-- narrow:
--
-- >>> putDocW 5 (hsep docs)
-- lorem ipsum dolor sit amet
--
-- For automatic line breaks, consider using 'fillSep' instead.
hsep :: [Doc ann] -> Doc ann
hsep = concatWith (<+>)

-- | @('vsep' xs)@ concatenates all documents @xs@ above each other. If a
-- 'group' undoes the line breaks inserted by @vsep@, the documents are
-- separated with a 'space' instead.
--
-- Using 'vsep' alone yields
--
-- >>> "prefix" <+> vsep ["text", "to", "lay", "out"]
-- prefix text
-- to
-- lay
-- out
--
-- 'group'ing a 'vsep' separates the documents with a 'space' if it fits the
-- page (and does nothing otherwise). See the @'sep'@ convenience function for
-- this use case.
--
-- The 'align' function can be used to align the documents under their first
-- element:
--
-- >>> "prefix" <+> align (vsep ["text", "to", "lay", "out"])
-- prefix text
--        to
--        lay
--        out
--
-- Since 'group'ing a 'vsep' is rather common, 'sep' is a built-in for doing
-- that.
vsep :: [Doc ann] -> Doc ann
vsep = concatWith (\x y -> x <> line <> y)

-- | @('fillSep' xs)@ concatenates the documents @xs@ horizontally with @'<+>'@
-- as long as it fits the page, then inserts a @'line'@ and continues doing that
-- for all documents in @xs@. (@'line'@ means that if 'group'ed, the documents
-- are separated with a 'space' instead of newlines. Use 'fillCat' if you do not
-- want a 'space'.)
--
-- Let's print some words to fill the line:
--
-- >>> let docs = take 20 (cycle ["lorem", "ipsum", "dolor", "sit", "amet"])
-- >>> putDocW 80 ("Docs:" <+> fillSep docs)
-- Docs: lorem ipsum dolor sit amet lorem ipsum dolor sit amet lorem ipsum dolor
-- sit amet lorem ipsum dolor sit amet
--
-- The same document, printed at a width of only 40, yields
--
-- >>> putDocW 40 ("Docs:" <+> fillSep docs)
-- Docs: lorem ipsum dolor sit amet lorem
-- ipsum dolor sit amet lorem ipsum dolor
-- sit amet lorem ipsum dolor sit amet
fillSep :: [Doc ann] -> Doc ann
fillSep = concatWith (\x y -> x <> softline <> y)

-- | @('sep' xs)@ tries laying out the documents @xs@ separated with 'space's,
-- and if this does not fit the page, separates them with newlines. This is what
-- differentiates it from 'vsep', which always lays out its contents beneath
-- each other.
--
-- >>> let doc = "prefix" <+> sep ["text", "to", "lay", "out"]
-- >>> putDocW 80 doc
-- prefix text to lay out
--
-- With a narrower layout, the entries are separated by newlines:
--
-- >>> putDocW 20 doc
-- prefix text
-- to
-- lay
-- out
--
-- @
-- 'sep' = 'group' . 'vsep'
-- @
sep :: [Doc ann] -> Doc ann
sep = group . vsep



-- | @('hcat' xs)@ concatenates all documents @xs@ horizontally with @'<>'@
-- (i.e. without any spacing).
--
-- It is provided only for consistency, since it is identical to 'mconcat'.
--
-- >>> let docs = Util.words "lorem ipsum dolor"
-- >>> hcat docs
-- loremipsumdolor
hcat :: [Doc ann] -> Doc ann
hcat = concatWith (<>)

-- | @('vcat' xs)@ vertically concatenates the documents @xs@. If it is
-- 'group'ed, the line breaks are removed.
--
-- In other words @'vcat'@ is like @'vsep'@, with newlines removed instead of
-- replaced by 'space's.
--
-- >>> let docs = Util.words "lorem ipsum dolor"
-- >>> vcat docs
-- lorem
-- ipsum
-- dolor
-- >>> group (vcat docs)
-- loremipsumdolor
--
-- Since 'group'ing a 'vcat' is rather common, 'cat' is a built-in shortcut for
-- it.
vcat :: [Doc ann] -> Doc ann
vcat = concatWith (\x y -> x <> line' <> y)

-- | @('fillCat' xs)@ concatenates documents @xs@ horizontally with @'<>'@ as
-- long as it fits the page, then inserts a @'line''@ and continues doing that
-- for all documents in @xs@. This is similar to how an ordinary word processor
-- lays out the text if you just keep typing after you hit the maximum line
-- length.
--
-- (@'line''@ means that if 'group'ed, the documents are separated with nothing
-- instead of newlines. See 'fillSep' if you want a 'space' instead.)
--
-- Observe the difference between 'fillSep' and 'fillCat'. 'fillSep'
-- concatenates the entries 'space'd when 'group'ed,
--
-- >>> let docs = take 20 (cycle (["lorem", "ipsum", "dolor", "sit", "amet"]))
-- >>> putDocW 40 ("Grouped:" <+> group (fillSep docs))
-- Grouped: lorem ipsum dolor sit amet
-- lorem ipsum dolor sit amet lorem ipsum
-- dolor sit amet lorem ipsum dolor sit
-- amet
--
-- On the other hand, 'fillCat' concatenates the entries directly when
-- 'group'ed,
--
-- >>> putDocW 40 ("Grouped:" <+> group (fillCat docs))
-- Grouped: loremipsumdolorsitametlorem
-- ipsumdolorsitametloremipsumdolorsitamet
-- loremipsumdolorsitamet
fillCat :: [Doc ann] -> Doc ann
fillCat = concatWith (\x y -> x <> softline' <> y)

-- | @('cat' xs)@ tries laying out the documents @xs@ separated with nothing,
-- and if this does not fit the page, separates them with newlines. This is what
-- differentiates it from 'vcat', which always lays out its contents beneath
-- each other.
--
-- >>> let docs = Util.words "lorem ipsum dolor"
-- >>> putDocW 80 ("Docs:" <+> cat docs)
-- Docs: loremipsumdolor
--
-- When there is enough space, the documents are put above one another,
--
-- >>> putDocW 10 ("Docs:" <+> cat docs)
-- Docs: lorem
-- ipsum
-- dolor
--
-- @
-- 'cat' = 'group' . 'vcat'
-- @
cat :: [Doc ann] -> Doc ann
cat = group . vcat



-- | @('punctuate' p xs)@ appends @p@ to all but the last document in @xs@.
--
-- >>> let docs = punctuate comma (Util.words "lorem ipsum dolor sit amet")
-- >>> putDocW 80 (hsep docs)
-- lorem, ipsum, dolor, sit, amet
--
-- The separators are put at the end of the entries, which we can see if we
-- position the result vertically:
--
-- >>> putDocW 20 (vsep docs)
-- lorem,
-- ipsum,
-- dolor,
-- sit,
-- amet
--
-- If you want put the commas in front of their elements instead of at the end,
-- you should use 'tupled' or, in general, 'encloseSep'.
punctuate
    :: Doc ann -- ^ Punctuation, e.g. 'comma'
    -> [Doc ann]
    -> [Doc ann]
punctuate p = go
  where
    go []     = []
    go [d]    = [d]
    go (d:ds) = (d <> p) : go ds



-- | Layout a document depending on which column it starts at. 'align' is
-- implemented in terms of 'column'.
--
-- >>> column (\l -> "Columns are" <+> pretty l <> "-based.")
-- Columns are 0-based.
--
-- >>> let doc = "prefix" <+> column (\l -> "| <- column" <+> pretty l)
-- >>> vsep [indent n doc | n <- [0,4,8]]
-- prefix | <- column 7
--     prefix | <- column 11
--         prefix | <- column 15
column :: (Int -> Doc ann) -> Doc ann
column = Column

-- | Layout a document depending on the current 'nest'ing level. 'align' is
-- implemented in terms of 'nesting'.
--
-- >>> let doc = "prefix" <+> nesting (\l -> brackets ("Nested:" <+> pretty l))
-- >>> vsep [indent n doc | n <- [0,4,8]]
-- prefix [Nested: 0]
--     prefix [Nested: 4]
--         prefix [Nested: 8]
nesting :: (Int -> Doc ann) -> Doc ann
nesting = Nesting

-- | @('width' doc f)@ lays out the document 'doc', and makes the column width
-- of it available to a function.
--
-- >>> let annotate doc = width (brackets doc) (\w -> " <- width:" <+> pretty w)
-- >>> align (vsep (map annotate ["---", "------", indent 3 "---", vsep ["---", indent 4 "---"]]))
-- [---] <- width: 5
-- [------] <- width: 8
-- [   ---] <- width: 8
-- [---
--     ---] <- width: 8
width :: Doc ann -> (Int -> Doc ann) -> Doc ann
width doc f
  = column (\colStart ->
        doc <> column (\colEnd ->
            f (colEnd - colStart)))

-- | Layout a document depending on the page width, if one has been specified.
--
-- >>> let prettyPageWidth (AvailablePerLine l r) = "Width:" <+> pretty l <> ", ribbon fraction:" <+> pretty r
-- >>> let doc = "prefix" <+> pageWidth (brackets . prettyPageWidth)
-- >>> putDocW 32 (vsep [indent n doc | n <- [0,4,8]])
-- prefix [Width: 32, ribbon fraction: 1.0]
--     prefix [Width: 32, ribbon fraction: 1.0]
--         prefix [Width: 32, ribbon fraction: 1.0]
pageWidth :: (PageWidth -> Doc ann) -> Doc ann
pageWidth = WithPageWidth



-- | @('fill' i x)@ lays out the document @x@. It then appends @space@s until
-- the width is equal to @i@. If the width of @x@ is already larger, nothing is
-- appended.
--
-- This function is quite useful in practice to output a list of bindings:
--
-- >>> let types = [("empty","Doc"), ("nest","Int -> Doc -> Doc"), ("fillSep","[Doc] -> Doc")]
-- >>> let ptype (name, tp) = fill 5 (pretty name) <+> "::" <+> pretty tp
-- >>> "let" <+> align (vcat (map ptype types))
-- let empty :: Doc
--     nest  :: Int -> Doc -> Doc
--     fillSep :: [Doc] -> Doc
fill
    :: Int -- ^ Append spaces until the document is at least this wide
    -> Doc ann
    -> Doc ann
fill n doc = width doc (\w -> spaces (n - w))

-- | @('fillBreak' i x)@ first lays out the document @x@. It then appends @space@s
-- until the width is equal to @i@. If the width of @x@ is already larger than
-- @i@, the nesting level is increased by @i@ and a @line@ is appended. When we
-- redefine @ptype@ in the example given in 'fill' to use @'fillBreak'@, we get
-- a useful variation of the output:
--
-- >>> let types = [("empty","Doc"), ("nest","Int -> Doc -> Doc"), ("fillSep","[Doc] -> Doc")]
-- >>> let ptype (name, tp) = fillBreak 5 (pretty name) <+> "::" <+> pretty tp
-- >>> "let" <+> align (vcat (map ptype types))
-- let empty :: Doc
--     nest  :: Int -> Doc -> Doc
--     fillSep
--           :: [Doc] -> Doc
fillBreak
    :: Int -- ^ Append spaces until the document is at least this wide
    -> Doc ann
    -> Doc ann
fillBreak f x = width x (\w ->
    if w > f
        then nest f line'
        else spaces (f - w))

-- | Insert a number of spaces. Negative values count as 0.
spaces :: Int -> Doc ann
spaces n = unsafeTextWithoutNewlines (T.replicate n " ")

-- $
-- prop> \(NonNegative n) -> length (show (spaces n)) == n
--
-- >>> case spaces 1 of Char ' ' -> True; _ -> False
-- True
--
-- >>> case spaces 0 of Empty -> True; _ -> False
-- True
--
-- prop> \(Positive n) -> case (spaces (-n)) of Empty -> True; _ -> False



-- | @('plural' n one many)@ is @one@ if @n@ is @1@, and @many@ otherwise. A
-- typical use case is  adding a plural "s".
--
-- >>> let things = [True]
-- >>> let amount = length things
-- >>> pretty things <+> "has" <+> pretty amount <+> plural "entry" "entries" amount
-- [True] has 1 entry
plural
    :: (Num amount, Eq amount)
    => doc -- ^ @1@ case
    -> doc -- ^ other cases
    -> amount
    -> doc
plural one multiple n
    | n == 1    = one
    | otherwise = multiple

-- | @('enclose' l r x)@ encloses document @x@ between documents @l@ and @r@
-- using @'<>'@.
--
-- >>> enclose "A" "Z" "·"
-- A·Z
--
-- @
-- 'enclose' l r x = l '<>' x '<>' r
-- @
enclose
    :: Doc ann -- ^ L
    -> Doc ann -- ^ R
    -> Doc ann -- ^ x
    -> Doc ann -- ^ LxR
enclose l r x = l <> x <> r

-- | @('surround' x l r)@ surrounds document @x@ with @l@ and @r@.
--
-- >>> surround "·" "A" "Z"
-- A·Z
--
-- This is merely an argument reordering of @'enclose'@, but allows for
-- definitions like
--
-- >>> concatWith (surround ".") ["Data", "Text", "Prettyprint", "Doc"]
-- Data.Text.Prettyprint.Doc
surround
    :: Doc ann
    -> Doc ann
    -> Doc ann
    -> Doc ann
surround x l r = l <> x <> r



-- | >>> squotes "·"
-- '·'
squotes :: Doc ann -> Doc ann
squotes = enclose squote squote

-- | >>> dquotes "·"
-- "·"
dquotes :: Doc ann -> Doc ann
dquotes = enclose dquote dquote

-- | >>> parens "·"
-- (·)
parens :: Doc ann -> Doc ann
parens = enclose lparen rparen

-- | >>> angles "·"
-- <·>
angles :: Doc ann -> Doc ann
angles = enclose langle rangle

-- | >>> brackets "·"
-- [·]
brackets :: Doc ann -> Doc ann
brackets = enclose lbracket rbracket

-- | >>> braces "·"
-- {·}
braces :: Doc ann -> Doc ann
braces = enclose lbrace rbrace

-- | >>> squote
-- '
squote :: Doc ann
squote = "'"

-- | >>> dquote
-- "
dquote :: Doc ann
dquote = "\""

-- | >>> lparen
-- (
lparen :: Doc ann
lparen = "("

-- | >>> rparen
-- )
rparen :: Doc ann
rparen = ")"

-- | >>> langle
-- <
langle :: Doc ann
langle = "<"

-- | >>> rangle
-- >
rangle :: Doc ann
rangle = ">"

-- | >>> lbracket
-- [
lbracket :: Doc ann
lbracket = "["
-- | >>> rbracket
-- ]
rbracket :: Doc ann
rbracket = "]"

-- | >>> lbrace
-- {
lbrace :: Doc ann
lbrace = "{"
-- | >>> rbrace
-- }
rbrace :: Doc ann
rbrace = "}"

-- | >>> semi
-- ;
semi :: Doc ann
semi = ";"

-- | >>> colon
-- :
colon :: Doc ann
colon = ":"

-- | >>> comma
-- ,
comma :: Doc ann
comma = ","

-- | >>> "a" <> space <> "b"
-- a b
--
-- This is mostly used via @'<+>'@,
--
-- >>> "a" <+> "b"
-- a b
space :: Doc ann
space = " "

-- | >>> dot
-- .
dot :: Doc ann
dot = "."

-- | >>> slash
-- /
slash :: Doc ann
slash = "/"

-- | >>> backslash
-- \\

backslash :: Doc ann
backslash = "\\"

-- | >>> equals
-- =
equals :: Doc ann
equals = "="

-- | >>> pipe
-- |
pipe :: Doc ann
pipe = "|"



-- | Add an annotation to a @'Doc'@. This annotation can then be used by the
-- renderer to e.g. add color to certain parts of the output. For a full
-- tutorial example on how to use it, see the
-- "Data.Text.Prettyprint.Doc.Render.Tutorials.StackMachineTutorial" or
-- "Data.Text.Prettyprint.Doc.Render.Tutorials.TreeRenderingTutorial" modules.
--
-- This function is only relevant for custom formats with their own annotations,
-- and not relevant for basic prettyprinting. The predefined renderers, e.g.
-- "Data.Text.Prettyprint.Doc.Render.Text", should be enough for the most common
-- needs.
annotate :: ann -> Doc ann -> Doc ann
annotate = Annotated

-- | Remove all annotations.
--
-- Although 'unAnnotate' is idempotent with respect to rendering,
--
-- @
-- 'unAnnotate' . 'unAnnotate' = 'unAnnotate'
-- @
--
-- it should not be used without caution, for each invocation traverses the
-- entire contained document. If possible, it is preferrable to unannotate after
-- producing the layout by using 'unAnnotateS'.
unAnnotate :: Doc ann -> Doc xxx
unAnnotate = alterAnnotations (const Nothing)

-- | Change the annotation of a 'Doc'ument.
--
-- Useful in particular to embed documents with one form of annotation in a more
-- generlly annotated document.
--
-- Since this traverses the entire @'Doc'@ tree, including parts that are not
-- rendered due to other layouts fitting better, it is preferrable to reannotate
-- after producing the layout by using @'reAnnotateS'@.
--
-- Since @'reAnnotate'@ has the right type and satisfies @'reAnnotate id = id'@,
-- it is used to define the @'Functor'@ instance of @'Doc'@.
reAnnotate :: (ann -> ann') -> Doc ann -> Doc ann'
reAnnotate re = alterAnnotations (Just . re)

-- | Change the annotation of a 'Doc'ument to a different one, or none at all.
--
-- This is a general function that combines 'unAnnotate' and 'reAnnotate', and
-- it is useful for mapping semantic annotations (such as »this is a keyword«)
-- to display annotations (such as »this is red«), because some backends may not
-- care about certain annotations, while others may.
--
-- Since this traverses the entire @'Doc'@ tree, including parts that are not
-- rendered due to other layouts fitting better, it is preferrable to reannotate
-- after producing the layout by using @'alterAnnotationsS'@.
alterAnnotations :: (ann -> Maybe ann') -> Doc ann -> Doc ann'
alterAnnotations re = go
  where
    go = \case
        Fail     -> Fail
        Empty    -> Empty
        Char c   -> Char c
        Text l t -> Text l t
        Line     -> Line

        FlatAlt x y     -> FlatAlt (go x) (go y)
        Cat x y         -> Cat (go x) (go y)
        Nest i x        -> Nest i (go x)
        Union x y       -> Union (go x) (go y)
        Column f        -> Column (go . f)
        WithPageWidth f -> WithPageWidth (go . f)
        Nesting f       -> Nesting (go . f)
        Annotated ann x -> case re ann of
            Nothing   -> go x
            Just ann' -> Annotated ann' (go x)

-- | Remove all annotations. 'unAnnotate' for 'SimpleDocStream'.
unAnnotateS :: SimpleDocStream ann -> SimpleDocStream xxx
unAnnotateS = alterAnnotationsS (const Nothing)

-- | Change the annotation of a document. 'reAnnotate' for 'SimpleDocStream'.
reAnnotateS :: (ann -> ann') -> SimpleDocStream ann -> SimpleDocStream ann'
reAnnotateS re = alterAnnotationsS (Just . re)

-- | Change the annotation of a document to a different annotation, or none at
-- all. 'alterAnnotations' for 'SimpleDocStream'.
alterAnnotationsS :: (ann -> Maybe ann') -> SimpleDocStream ann -> SimpleDocStream ann'
alterAnnotationsS re = go
  where
    go = \case
        SFail             -> SFail
        SEmpty            -> SEmpty
        SChar c rest      -> SChar c (go rest)
        SText l t rest    -> SText l t (go rest)
        SLine l rest      -> SLine l (go rest)
        SAnnPop rest      -> SAnnPop (go rest)
        SAnnPush ann rest -> case re ann of
            Nothing   -> go rest
            Just ann' -> SAnnPush ann' (go rest)


-- | Fusion depth parameter, used by 'fuse'.
data FusionDepth =

    -- | Do not dive deep into nested documents, fusing mostly concatenations of
    -- text nodes together.
    Shallow

    -- | Recurse into all parts of the 'Doc', including different layout
    -- alternatives, and location-sensitive values such as created by 'nesting'
    -- which cannot be fused before, but only during, the layout process. As a
    -- result, the performance cost of using deep fusion is often hard to
    -- predict, and depends on the interplay between page layout and document to
    -- prettyprint.
    --
    -- This value should only be used if profiling shows it is significantly
    -- faster than using 'Shallow'.
    | Deep
    deriving (Eq, Ord, Show)

-- | @('fuse' depth doc)@ combines text nodes so they can be rendered more
-- efficiently. A fused document is always laid out identical to its unfused
-- version.
--
-- When laying a 'Doc'ument out to a 'SimpleDocStream', every component of the
-- input is translated directly to the simpler output format. This sometimes
-- yields undesirable chunking when many pieces have been concatenated together.
--
-- For example
--
-- >>> "a" <> "b" <> pretty 'c' <> "d"
-- abcd
--
-- results in a chain of four entries in a 'SimpleDocStream', although this is fully
-- equivalent to the tightly packed
--
-- >>> "abcd" :: Doc ann
-- abcd
--
-- which is only a single 'SimpleDocStream' entry, and can be processed faster.
--
-- It is therefore a good idea to run 'fuse' on concatenations of lots of small
-- strings that are used many times,
--
-- >>> let oftenUsed = fuse Shallow ("a" <> "b" <> pretty 'c' <> "d")
-- >>> hsep (replicate 5 oftenUsed)
-- abcd abcd abcd abcd abcd
fuse :: FusionDepth -> Doc ann -> Doc ann
fuse depth = go
  where
    go = \case
        Cat Empty x                   -> go x
        Cat x Empty                   -> go x
        Cat (Char c1) (Char c2)       -> Text 2 (T.singleton c1 <> T.singleton c2)
        Cat (Text lt t) (Char c)      -> Text (lt+1) (T.snoc t c)
        Cat (Char c) (Text lt t)      -> Text (1+lt) (T.cons c t)
        Cat (Text l1 t1) (Text l2 t2) -> Text (l1+l2) (t1 <> t2)

        Cat x@Char{} (Cat y@Char{} z) -> go (Cat (go (Cat x y)) z)
        Cat x@Text{} (Cat y@Char{} z) -> go (Cat (go (Cat x y)) z)
        Cat x@Char{} (Cat y@Text{} z) -> go (Cat (go (Cat x y)) z)
        Cat x@Text{} (Cat y@Text{} z) -> go (Cat (go (Cat x y)) z)

        Cat (Cat x y@Char{}) z -> go (Cat x (go (Cat y z)))
        Cat (Cat x y@Text{}) z -> go (Cat x (go (Cat y z)))

        Cat x y -> Cat (go x) (go y)

        Nest i (Nest j x) -> let !fused = Nest (i+j) x
                             in go fused
        Nest _ x@Empty{} -> x
        Nest _ x@Text{}  -> x
        Nest _ x@Char{}  -> x
        Nest 0 x         -> go x
        Nest i x         -> Nest i (go x)

        Annotated _ Empty -> Empty

        FlatAlt x1 x2 -> FlatAlt (go x1) (go x2)
        Union x1 x2   -> Union (go x1) (go x2)

        other | depth == Shallow -> other

        Column f        -> Column (go . f)
        WithPageWidth f -> WithPageWidth (go . f)
        Nesting f       -> Nesting (go . f)

        other -> other



-- | The data type @SimpleDocStream@ represents laid out documents and is used
-- by the display functions.
--
-- A simplified view is that @'Doc' = ['SimpleDocStream']@, and the layout
-- functions pick one of the 'SimpleDocStream's based on which one fits the
-- layout constraints best. This means that 'SimpleDocStream' has all complexity
-- contained in 'Doc' resolved, making it very easy to convert it to other
-- formats, such as plain text or terminal output.
--
-- To write your own @'Doc'@ to X converter, it is therefore sufficient to
-- convert from @'SimpleDocStream'@. The »Render« submodules provide some
-- built-in converters to do so, and helpers to create own ones.
data SimpleDocStream ann =
      SFail
    | SEmpty
    | SChar Char (SimpleDocStream ann)

    -- | Some layout algorithms use the Since the frequently used 'T.length' of
    -- the 'Text', which scales linearly with its length, we cache it in this
    -- constructor.
    | SText !Int Text (SimpleDocStream ann)

    -- | @Int@ = indentation level for the line
    | SLine !Int (SimpleDocStream ann)

    -- | Add an annotation to the remaining document.
    | SAnnPush ann (SimpleDocStream ann)

    -- | Remove a previously pushed annotation.
    | SAnnPop (SimpleDocStream ann)
    deriving (Eq, Ord, Show, Generic)

-- | Alter the document’s annotations.
--
-- This instance makes 'SimpleDocStream' more flexible (because it can be used in
-- 'Functor'-polymorphic values), but @'fmap'@ is much less readable compared to
-- using @'reAnnotateST'@ in code that only works for @'SimpleDocStream'@ anyway.
-- Consider using the latter when the type does not matter.
instance Functor SimpleDocStream where
    fmap = reAnnotateS

-- | Collect all annotations from a document.
instance Foldable SimpleDocStream where
    foldMap f = go
      where
        go = \case
            SFail             -> mempty
            SEmpty            -> mempty
            SChar _ rest      -> go rest
            SText _ _ rest    -> go rest
            SLine _ rest      -> go rest
            SAnnPush ann rest -> f ann `mappend` go rest
            SAnnPop rest      -> go rest

-- | Transform a document based on its annotations, possibly leveraging
-- 'Applicative' effects.
instance Traversable SimpleDocStream where
    traverse f = go
      where
        go = \case
            SFail             -> pure SFail
            SEmpty            -> pure SEmpty
            SChar c rest      -> SChar c   <$> go rest
            SText l t rest    -> SText l t <$> go rest
            SLine i rest      -> SLine i   <$> go rest
            SAnnPush ann rest -> SAnnPush  <$> f ann <*> go rest
            SAnnPop rest      -> SAnnPop   <$> go rest

-- | Decide whether a 'SimpleDocStream' fits the constraints given, namely
--
--   - page width
--   - minimum nesting level to fit in
--   - width in which to fit the first line; Nothing is unbounded
newtype FittingPredicate ann
  = FittingPredicate (PageWidth
                   -> Int
                   -> Maybe Int
                   -> SimpleDocStream ann
                   -> Bool)

-- | List of nesting level/document pairs yet to be laid out.
data LayoutPipeline ann =
      Nil
    | Cons !Int (Doc ann) (LayoutPipeline ann)
    | UndoAnn (LayoutPipeline ann)

-- | Maximum number of characters that fit in one line. The layout algorithms
-- will try not to exceed the set limit by inserting line breaks when applicable
-- (e.g. via 'softline'').
data PageWidth

    = AvailablePerLine Int Double
    -- ^ Layouters should not exceed the specified space per line.
    --
    --   - The 'Int' is the number of characters, including whitespace, that
    --     fit in a line. A typical value is 80.
    --
    --   - The 'Double' is the ribbon with, i.e. the fraction of the total
    --     page width that can be printed on. This allows limiting the length
    --     of printable text per line. Values must be between 0 and 1, and
    --     0.4 to 1 is typical.

    | Unbounded
    -- ^ Layouters should not introduce line breaks on their own.

    deriving (Eq, Ord, Show)

-- $ Test to avoid surprising behaviour
-- >>> Unbounded > AvailablePerLine maxBound 1
-- True

-- | Options to influence the layout algorithms.
newtype LayoutOptions = LayoutOptions { layoutPageWidth :: PageWidth }
    deriving (Eq, Ord, Show)

-- | The default layout options, suitable when you just want some output, and
-- don’t particularly care about the details. Used by the 'Show' instance, for
-- example.
--
-- >>> defaultLayoutOptions
-- LayoutOptions {layoutPageWidth = AvailablePerLine 80 0.4}
defaultLayoutOptions :: LayoutOptions
defaultLayoutOptions = LayoutOptions { layoutPageWidth = AvailablePerLine 80 0.4 }

-- | This is the default layout algorithm, and it is used by 'show', 'putDoc'
-- and 'hPutDoc'.
--
-- @'layoutPretty'@ commits to rendering something in a certain way if the next
-- element fits the layout constraints; in other words, it has one
-- 'SimpleDocStream' element lookahead when rendering. Consider using the
-- smarter, but a bit less performant, @'layoutSmart'@ algorithm if the results
-- seem to run off to the right before having lots of line breaks.
layoutPretty
    :: LayoutOptions
    -> Doc ann
    -> SimpleDocStream ann
layoutPretty = layoutWadlerLeijen
    (FittingPredicate (\_pWidth _minNestingLevel maxWidth sdoc -> case maxWidth of
        Nothing -> True
        Just w -> fits w sdoc ))
  where
    fits :: Int -- ^ Width in which to fit the first line
         -> SimpleDocStream ann
         -> Bool
    fits w _ | w < 0      = False
    fits _ SFail          = False
    fits _ SEmpty         = True
    fits w (SChar _ x)    = fits (w - 1) x
    fits w (SText l _t x) = fits (w - l) x
    fits _ SLine{}        = True
    fits w (SAnnPush _ x) = fits w x
    fits w (SAnnPop x)    = fits w x

-- | A layout algorithm with more lookahead than 'layoutPretty', that introduces
-- line breaks earlier if the content does not (or will not, rather) fit into
-- one line.
--
-- Considre the following python-ish document,
--
-- >>> let fun x = hang 2 ("fun(" <> softline' <> x) <> ")"
-- >>> let doc = (fun . fun . fun . fun . fun) (list ["abcdef", "ghijklm"])
--
-- which we’ll be rendering using the following pipeline (where the layout
-- algorithm has been left open),
--
-- >>> import Data.Text.IO as T
-- >>> import Data.Text.Prettyprint.Doc.Render.Text
-- >>> let hr = pipe <> pretty (replicate (26-2) '-') <> pipe
-- >>> let go layouter x = (T.putStrLn . renderStrict . layouter (LayoutOptions (AvailablePerLine 26 1))) (vsep [hr, x, hr])
--
-- If we render this using @'layoutPretty'@ with a page width of 26 characters
-- per line, all the @fun@ calls fit into the first line so they will be put
-- there,
--
-- >>> go layoutPretty doc
-- |------------------------|
-- fun(fun(fun(fun(fun(
--                   [ abcdef
--                   , ghijklm ])))))
-- |------------------------|
--
-- Note that this exceeds the desired 26 character page width. The same
-- document, rendered with @'layoutSmart'@, fits the layout contstraints:
--
-- >>> go layoutSmart doc
-- |------------------------|
-- fun(
--   fun(
--     fun(
--       fun(
--         fun(
--           [ abcdef
--           , ghijklm ])))))
-- |------------------------|
--
-- The key difference between @'layoutPretty'@ and @'layoutSmart'@ is that the
-- latter will check the potential document up to the end of the current
-- indentation level, instead of just having one element lookahead.
layoutSmart
    :: LayoutOptions
    -> Doc ann
    -> SimpleDocStream ann
layoutSmart = layoutWadlerLeijen
    (FittingPredicate (\pWidth minNestingLevel maxWidth sdoc -> case maxWidth of
        Nothing -> False
        Just w -> fits pWidth minNestingLevel w sdoc ))
  where
    -- Search with more lookahead: assuming that nesting roughly corresponds to
    -- syntactic depth, @fits@ checks that not only the current line fits, but
    -- the entire syntactic structure being formatted at this level of
    -- indentation fits. If we were to remove the second case for @SLine@, we
    -- would check that not only the current structure fits, but also the rest
    -- of the document, which would be slightly more intelligent but would have
    -- exponential runtime (and is prohibitively expensive in practice).
    fits :: PageWidth
         -> Int -- ^ Minimum nesting level to fit in
         -> Int -- ^ Width in which to fit the first line
         -> SimpleDocStream ann
         -> Bool
    fits _ _ w _ | w < 0                    = False
    fits _ _ _ SFail                        = False
    fits _ _ _ SEmpty                       = True
    fits pw m w (SChar _ x)                 = fits pw m (w - 1) x
    fits pw m w (SText l _t x)              = fits pw m (w - l) x
    fits pw m _ (SLine i x)
      | m < i, AvailablePerLine cpl _ <- pw = fits pw m (cpl - i) x
      | otherwise                           = True
    fits pw m w (SAnnPush _ x)              = fits pw m w x
    fits pw m w (SAnnPop x)                 = fits pw m w x

-- | The Wadler/Leijen layout algorithm
layoutWadlerLeijen
    :: forall ann. FittingPredicate ann
    -> LayoutOptions
    -> Doc ann
    -> SimpleDocStream ann
layoutWadlerLeijen
    fittingPredicate
    LayoutOptions { layoutPageWidth = pWidth }
    doc
  = best 0 0 (Cons 0 doc Nil)
  where

    -- * current column >= current nesting level
    -- * current column - current indentaion = number of chars inserted in line
    best
        :: Int -- Current nesting level
        -> Int -- Current column, i.e. "where the cursor is"
        -> LayoutPipeline ann -- Documents remaining to be handled (in order)
        -> SimpleDocStream ann
    best !_ !_ Nil           = SEmpty
    best nl cc (UndoAnn ds)  = SAnnPop (best nl cc ds)
    best nl cc (Cons i d ds) = case d of
        Fail            -> SFail
        Empty           -> best nl cc ds
        Char c          -> let !cc' = cc+1 in SChar c (best nl cc' ds)
        Text l t        -> let !cc' = cc+l in SText l t (best nl cc' ds)
        Line            -> SLine i (best i i ds)
        FlatAlt x _     -> best nl cc (Cons i x ds)
        Cat x y         -> best nl cc (Cons i x (Cons i y ds))
        Nest j x        -> let !ij = i+j in best nl cc (Cons ij x ds)
        Union x y       -> let x' = best nl cc (Cons i x ds)
                               y' = best nl cc (Cons i y ds)
                           in selectNicer fittingPredicate nl cc x' y'
        Column f        -> best nl cc (Cons i (f cc) ds)
        WithPageWidth f -> best nl cc (Cons i (f pWidth) ds)
        Nesting f       -> best nl cc (Cons i (f i) ds)
        Annotated ann x -> SAnnPush ann (best nl cc (Cons i x (UndoAnn ds)))

    selectNicer
        :: FittingPredicate ann
        -> Int           -- ^ Current nesting level
        -> Int           -- ^ Current column
        -> SimpleDocStream ann -- ^ Choice A. Invariant: first lines should not be longer than B's.
        -> SimpleDocStream ann -- ^ Choice B.
        -> SimpleDocStream ann -- ^ Choice A if it fits, otherwise B.
    selectNicer (FittingPredicate fits) lineIndent currentColumn x y
      | fits pWidth minNestingLevel availableWidth x = x
      | otherwise = y
      where
        minNestingLevel = min lineIndent currentColumn
        ribbonWidth = case pWidth of
            AvailablePerLine lineLength ribbonFraction ->
                (Just . max 0 . min lineLength . round)
                    (fromIntegral lineLength * ribbonFraction)
            Unbounded -> Nothing
        availableWidth = do
            columnsLeftInLine <- case pWidth of
                AvailablePerLine cpl _ribbonFrac -> Just (cpl - currentColumn)
                Unbounded -> Nothing
            columnsLeftInRibbon <- do
                li <- Just lineIndent
                rw <- ribbonWidth
                cc <- Just currentColumn
                Just (li + rw - cc)
            Just (min columnsLeftInLine columnsLeftInRibbon)

-- | @(layoutCompact x)@ lays out the document @x@ without adding any
-- indentation. Since no \'pretty\' printing is involved, this layouter is very
-- fast. The resulting output contains fewer characters than a prettyprinted
-- version and can be used for output that is read by other programs.
--
-- This layout function does not add any colorisation information.
--
-- >>> let doc = hang 4 (vsep ["lorem", "ipsum", hang 4 (vsep ["dolor", "sit"])])
-- >>> doc
-- lorem
--     ipsum
--     dolor
--         sit
--
-- >>> let putDocCompact = renderIO System.IO.stdout . layoutCompact
-- >>> putDocCompact doc
-- lorem
-- ipsum
-- dolor
-- sit
layoutCompact :: Doc ann -> SimpleDocStream ann
layoutCompact doc = scan 0 [doc]
  where
    scan _ [] = SEmpty
    scan !col (d:ds) = case d of
        Fail            -> SFail
        Empty           -> scan col ds
        Char c          -> SChar c (scan (col+1) ds)
        Text l t        -> let !col' = col+l in SText l t (scan col' ds)
        FlatAlt x _     -> scan col (x:ds)
        Line            -> SLine 0 (scan 0 ds)
        Cat x y         -> scan col (x:y:ds)
        Nest _ x        -> scan col (x:ds)
        Union _ y       -> scan col (y:ds)
        Column f        -> scan col (f col:ds)
        WithPageWidth f -> scan col (f Unbounded : ds)
        Nesting f       -> scan col (f 0 : ds)
        Annotated _ x   -> scan col (x:ds)

-- | @('show' doc)@ prettyprints document @doc@ with 'defaultLayoutOptions',
-- ignoring all annotations.
instance Show (Doc ann) where
    showsPrec _ doc = renderShowS (layoutPretty defaultLayoutOptions doc)

-- | Render a 'SimpleDocStream' to a 'ShowS', useful to write 'Show' instances
-- based on the prettyprinter.
--
-- @
-- instance 'Show' MyType where
--     'showsPrec' _ = 'renderShowS' . 'layoutPretty' 'defaultLayoutOptions' . 'pretty'
-- @
renderShowS :: SimpleDocStream ann -> ShowS
renderShowS = \case
    SFail        -> panicUncaughtFail
    SEmpty       -> id
    SChar c x    -> showChar c . renderShowS x
    SText _l t x -> showString (T.unpack t) . renderShowS x
    SLine i x    -> showString ('\n' : replicate i ' ') . renderShowS x
    SAnnPush _ x -> renderShowS x
    SAnnPop x    -> renderShowS x



-- $setup
--
-- (Definitions for the doctests)
--
-- >>> :set -XOverloadedStrings
-- >>> import Data.Text.Prettyprint.Doc.Render.Text
-- >>> import Data.Text.Prettyprint.Doc.Util as Util
-- >>> import Test.QuickCheck.Modifiers
