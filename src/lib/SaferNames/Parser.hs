-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

module SaferNames.Parser (Parser, parseit, parseProg, runTheParser, parseData,
               parseTopDeclRepl, uint, withSource, parseExpr, exprAsModule,
               emptyLines, brackets, symbol, symChar, keyWordStrs) where

import Control.Monad
import Control.Monad.Combinators.Expr
import Control.Monad.Reader
import Text.Megaparsec hiding (Label, State)
import Text.Megaparsec.Char hiding (space, eol)
import qualified Text.Megaparsec.Char as MC
import Data.Foldable (toList)
import Data.Functor
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Void
import qualified Data.Set as S
import Data.String (IsString, fromString)
import qualified Text.Megaparsec.Char.Lexer as L
import qualified Text.Megaparsec.Debug

import Err
import LabeledItems
import SaferNames.Name
import SaferNames.Syntax

-- canPair is used for the ops (,) (|) (&) which should only appear inside
-- parentheses (to avoid conflicts with records and other syntax)
data ParseCtx = ParseCtx { curIndent :: Int
                         , canPair   :: Bool
                         , canBreak  :: Bool }
type Parser = ReaderT ParseCtx (Parsec Void String)

parseProg :: String -> [SourceBlock]
parseProg s = mustParseit s $ manyTill (sourceBlock <* outputLines) eof

parseData :: String -> Except (UExpr VoidS)
parseData s = parseit s $ expr <* (optional eol >> eof)

parseTopDeclRepl :: String -> Maybe SourceBlock
parseTopDeclRepl s = case sbContents b of
  UnParseable True _ -> Nothing
  _ -> Just b
  where b = mustParseit s sourceBlock

parseExpr :: String -> Except (UExpr VoidS)
parseExpr s = parseit s (expr <* eof)

parseit :: String -> Parser a -> Except a
parseit s p = case runTheParser s (p <* (optional eol >> eof)) of
  Left e -> throw ParseErr (errorBundlePretty e)
  Right x -> return x

mustParseit :: String -> Parser a -> a
mustParseit s p  = case parseit s p of
  Right ans -> ans
  Left e -> error $ "This shouldn't happen:\n" ++ pprint e

importModule :: Parser SourceBlock'
importModule = ImportModule <$> do
  keyWord ImportKW
  s <- (:) <$> letterChar <*> many alphaNumChar
  eol
  return s

sourceBlock :: Parser SourceBlock
sourceBlock = do
  offset <- getOffset
  pos <- getSourcePos
  (src, (level, b)) <- withSource $ withRecovery recover $ do
    level <- logLevel <|> logTime <|> logBench <|> return LogNothing
    b <- sourceBlock'
    return (level, b)
  return $ SourceBlock (unPos (sourceLine pos)) offset level src b Nothing

recover :: ParseError String Void -> Parser (LogLevel, SourceBlock')
recover e = do
  pos <- liftM statePosState getParserState
  reachedEOF <-  try (mayBreak sc >> eof >> return True)
             <|> return False
  consumeTillBreak
  let errmsg = errorBundlePretty (ParseErrorBundle (e :| []) pos)
  return (LogNothing, UnParseable reachedEOF errmsg)

consumeTillBreak :: Parser ()
consumeTillBreak = void $ manyTill anySingle $ eof <|> void (try (eol >> eol))

logLevel :: Parser LogLevel
logLevel = do
  void $ try $ lexeme $ char '%' >> string "passes"
  passes <- many passName
  eol
  case passes of
    [] -> return LogAll
    _ -> return $ LogPasses passes

logTime :: Parser LogLevel
logTime = do
  void $ try $ lexeme $ char '%' >> string "time"
  eol
  return PrintEvalTime

logBench :: Parser LogLevel
logBench = do
  void $ try $ lexeme $ char '%' >> string "bench"
  benchName <- stringLiteral
  eol
  return $ PrintBench benchName

passName :: Parser PassName
passName = choice [thisNameString s $> x | (s, x) <- passNames]

passNames :: [(String, PassName)]
passNames = [(show x, x) | x <- [minBound..maxBound]]

sourceBlock' :: Parser SourceBlock'
sourceBlock' =
      proseBlock
  <|> topLevelCommand
  <|> liftM declToModule (topDecl <* eolf)
  <|> liftM declToModule (instanceDef True  <* eolf)
  <|> liftM declToModule (instanceDef False <* eolf)
  <|> liftM declToModule (interfaceDef <* eolf)
  <|> liftM (Command (EvalExpr Printed) . exprAsModule) (expr <* eol)
  <|> hidden (some eol >> return EmptyLines)
  <|> hidden (sc >> eol >> return CommentLine)
  where declToModule = RunModule . SourceUModule

proseBlock :: Parser SourceBlock'
proseBlock = label "prose block" $ char '\'' >> fmap (ProseBlock . fst) (withSource consumeTillBreak)

topLevelCommand :: Parser SourceBlock'
topLevelCommand =
      importModule
  <|> explicitCommand
  <?> "top-level command"

explicitCommand :: Parser SourceBlock'
explicitCommand = do
  cmdName <- char ':' >> nameString
  cmd <- case cmdName of
    "p"       -> return $ EvalExpr Printed
    "t"       -> return $ GetType
    "html"    -> return $ EvalExpr RenderHtml
    "export"  -> ExportFun <$> nameString
    _ -> fail $ "unrecognized command: " ++ show cmdName
  e <- blockOrExpr <* eolf
  return $ case (e, cmd) of
    (WithSrcE _ (UVar (SourceName v)), GetType) -> GetNameType v
    _ -> Command cmd (exprAsModule e)

exprAsModule :: UExpr VoidS -> (SourceName, SourceUModule)
exprAsModule e = (v, SourceUModule d)
  where
    v = "_ans_"
    d = ULet PlainLet (UPatAnn (WithSrcB (srcPos e) (fromString v)) Nothing) e

-- === uexpr ===

expr :: Parser (UExpr VoidS)
expr = mayNotPair $ makeExprParser leafExpr ops

-- expression without exposed infix operators
leafExpr :: Parser (UExpr VoidS)
leafExpr = parens (mayPair $ makeExprParser leafExpr ops)
         <|> uTabCon
         <|> uVarOcc
         <|> uHole
         <|> uString
         <|> uLit
         <|> uPiType
         <|> uLamExpr
         <|> uViewExpr
         <|> uForExpr
         <|> caseExpr
         <|> ifExpr
         <|> uPrim
         <|> unitCon
         <|> (uLabeledExprs `fallBackTo` uVariantExpr)
         <|> uIsoSugar
         <|> uDoSugar
         <?> "expression"

containedExpr :: Parser (UExpr VoidS)
containedExpr =   parens (mayPair $ makeExprParser leafExpr ops)
              <|> uVarOcc
              <|> uLabeledExprs
              <?> "contained expression"

uType :: Parser (UType VoidS)
uType = expr

uString :: Lexer (UExpr VoidS)
uString = do
  (s, pos) <- withPos $ strLit
  let addSrc = WithSrcE (Just pos)
  let cs = map (addSrc . charExpr) s
  return $ mkApp (addSrc "toList") $ addSrc $ UTabCon cs

uLit :: Parser (UExpr VoidS)
uLit = withSrc $ uLitParser
  where uLitParser = charExpr <$> charLit
                 <|> UIntLit  <$> intLit
                 <|> UFloatLit <$> doubleLit
                 <?> "literal"

charExpr :: Char -> (UExpr' VoidS)
charExpr c = UPrimExpr $ ConExpr $ Lit $ Word8Lit $ fromIntegral $ fromEnum c

uVarOcc :: Parser (UExpr VoidS)
uVarOcc = withSrc $ try $ fromString <$> (anyName <* notFollowedBy (sym ":"))

uHole :: Parser (UExpr VoidS)
uHole = withSrc $ underscore $> UHole

letAnnStr :: Parser LetAnn
letAnnStr =   (string "instance"   $> InstanceLet)
          <|> (string "noinline"   $> NoInlineLet)

topDecl :: Parser (UDecl VoidS VoidS)
topDecl = dataDef <|> topLet

topLet :: Parser (UDecl VoidS VoidS)
topLet = do
  lAnn <- (char '@' >> letAnnStr <* (eol <|> sc)) <|> return PlainLet
  ~(ULet _ p rhs) <- decl
  return $ ULet lAnn p rhs

superclassConstraints :: Parser [(UType VoidS)]
superclassConstraints = optionalMonoid $ brackets $ uType `sepBy` sym ","

interfaceDef :: Parser (UDecl VoidS VoidS)
interfaceDef = do
  keyWord InterfaceKW
  superclasses <- superclassConstraints
  (tyConName, tyConParams) <- tyConDef
  (methodNames, methodTys) <- unzip <$> onePerLine do
    v <- anyName
    ty <- annot uType
    return (fromString v, ty)
  let methodNames' :: Nest (UBinder MethodNameC) VoidS VoidS
      methodNames' = toNest methodNames
  let tyConParams' = tyConParams
  return $ UInterface tyConParams' superclasses methodTys (fromString tyConName) methodNames'

toNest :: (IsString (a VoidS VoidS)) => [String] -> Nest a VoidS VoidS
toNest = toNestParsed . map fromString

toNestParsed :: [a VoidS VoidS] -> Nest a VoidS VoidS
toNestParsed = foldr Nest Empty

toPairB :: forall a b. (IsString (a VoidS VoidS), IsString (b VoidS VoidS))
           => String -> String -> PairB a b VoidS VoidS
toPairB s1 s2 = PairB parse1 parse2 where
  parse1 :: a VoidS VoidS
  parse1 = fromString s1
  parse2 :: b VoidS VoidS
  parse2 = fromString s2

dataDef :: Parser (UDecl VoidS VoidS)
dataDef = do
  keyWord DataKW
  tyCon <- tyConDef
  sym "="
  dataCons <- onePerLine dataConDef
  return $ UDataDefDecl
    (UDataDef tyCon $ map (\(nm, cons) -> (nm, UDataDefTrail cons)) dataCons)
    (fromString $ fst tyCon)
    (toNest $ map (fromString . fst) $ dataCons)

tyConDef :: Parser (UConDef VoidS VoidS)
tyConDef = do
  con <- upperName <|> symName
  bs <- manyNested $ label "type constructor parameter" do
    v <- lowerName
    ty <- annot containedExpr <|> return tyKind
    return $  UAnnBinder (fromString v) ty
  return (fromString con, bs)
  where tyKind = ns $ UPrimExpr $ TCExpr TypeKind

-- TODO: dependent types
dataConDef :: Parser (UConDef VoidS VoidS)
dataConDef = (,) <$> upperName <*> manyNested dataConDefBinder

dataConDefBinder :: Parser (UAnnBinder AtomNameC VoidS VoidS)
dataConDefBinder = annBinder <|> (UAnnBinder UIgnore <$> containedExpr)

decl :: Parser (UDecl VoidS VoidS)
decl = do
  lhs <- simpleLet <|> funDefLet
  rhs <- sym "=" >> blockOrExpr
  return $ lhs rhs

instanceDef :: Bool -> Parser (UDecl VoidS VoidS)
instanceDef isNamed = do
  name <- case isNamed of
    False -> keyWord InstanceKW $> NothingB
    True  -> keyWord NamedInstanceKW *> (JustB . fromString <$> anyName) <* sym ":"
  explicitArgs <- many defArg
  constraints <- classConstraints
  className <- upperName
  params <- many leafExpr
  let argBinders = explicitArgs
                 ++ [UPatAnnArrow (UPatAnn (nsB UPatIgnore) (Just c)) ClassArrow | c <- constraints]
  methods <- onePerLine instanceMethod
  return $ UInstance (toNestParsed argBinders) (fromString className) params methods name

instanceMethod :: Parser (UMethodDef VoidS)
instanceMethod = do
  v <- anyName
  sym "="
  rhs <- blockOrExpr
  return $ UMethodDef (fromString v) rhs

simpleLet :: Parser (UExpr VoidS -> UDecl VoidS VoidS)
simpleLet = label "let binding" $ do
  letAnn <- (InstanceLet <$ string "%instance" <* sc) <|> (pure PlainLet)
  p <- try $ (letPat <|> leafPat) <* lookAhead (sym "=" <|> sym ":")
  typeAnn <- optional $ annot uType
  return $ ULet letAnn (UPatAnn p typeAnn)

letPat :: Parser (UPat VoidS VoidS)
letPat = withSrcB $ fromString <$> anyName

funDefLet :: Parser (UExpr VoidS -> UDecl VoidS VoidS)
funDefLet = label "function definition" $ mayBreak $ do
  keyWord DefKW
  v <- letPat
  cs <- classConstraints
  argBinders <- many defArg
  (eff, ty) <- label "result type annotation" $ annot effectiveType
  when (null argBinders && eff /= Pure) $ fail "Nullary def can't have effects"
  let bs = map classAsBinder cs ++ argBinders
  let funTy = buildPiType bs eff ty
  let letBinder = UPatAnn v (Just funTy)
  let lamBinders = flip map bs \(UPatAnnArrow (UPatAnn p _) arr) -> (UPatAnnArrow (UPatAnn p Nothing) arr)
  return \body -> ULet PlainLet letBinder (buildLam lamBinders body)
  where
    classAsBinder :: (UType (n::S)) -> UPatAnnArrow n n
    classAsBinder ty = UPatAnnArrow (UPatAnn (nsB UPatIgnore) (Just ty)) ClassArrow

defArg :: Parser (UPatAnnArrow VoidS VoidS)
defArg = label "def arg" $ do
  (p, ty) <- parens ((,) <$> pat <*> annot uType)
  arr <- bareArrow <|> return PlainArrow
  return $ UPatAnnArrow (UPatAnn p (Just ty)) arr

classConstraints :: Parser [(UType VoidS)]
classConstraints = label "class constraints" $
  optionalMonoid $ brackets $ mayNotPair $ uType `sepBy` sym ","

buildPiType :: [UPatAnnArrow VoidS VoidS] -> UEffectRow VoidS -> UType VoidS -> UType VoidS
buildPiType [] Pure ty = ty
buildPiType [] _ _ = error "shouldn't be possible"
buildPiType (UPatAnnArrow p arr : bs) eff resTy = ns case bs of
  [] -> UPi $ UPiExpr arr p eff resTy
  _  -> UPi $ UPiExpr arr p Pure $ buildPiType bs eff resTy

effectiveType :: Parser (UEffectRow VoidS, UType VoidS)
effectiveType = (,) <$> effects <*> uType

effects :: Parser (UEffectRow VoidS)
effects = braces someEffects <|> return Pure
  where
    someEffects = do
      effs <- effect `sepBy` sym ","
      v <- optional $ symbol "|" >> lowerName
      return $ EffectRow (S.fromList effs) $ fmap fromString v

effect :: Parser (UEffect VoidS)
effect =   (RWSEffect <$> rwsName <*> (fromString <$> anyCaseName))
       <|> (keyWord ExceptKW $> ExceptionEffect)
       <|> (keyWord IOKW     $> IOEffect)
       <?> "effect (Accum h | Read h | State h | Except | IO)"

rwsName :: Parser RWS
rwsName =   (keyWord WriteKW $> Writer)
        <|> (keyWord ReadKW  $> Reader)
        <|> (keyWord StateKW $> State)

uLamExpr :: Parser (UExpr VoidS)
uLamExpr = do
  sym "\\"
  bs <- some patAnn
  arrowType <-
    (argTerm >> return PlainArrow)
    <|> (bareArrow >>= \case
          PlainArrow -> fail
            "To construct an explicit lambda function, use '.' instead of '->'\n"
          TabArrow -> fail
            "To construct a table, use 'for i. body' instead of '\\i => body'\n"
          arr -> return arr)
  body <- blockOrExpr
  return $ buildLam (map (flip UPatAnnArrow arrowType) bs) body

-- TODO Does this generalize?  Swap list for Nest?
buildLam :: [UPatAnnArrow VoidS VoidS] -> UExpr VoidS -> UExpr VoidS
buildLam binders body@(WithSrcE pos _) = case binders of
  [] -> body
  -- TODO: join with source position of binders too
  (UPatAnnArrow b arr):bs -> WithSrcE (joinPos pos' pos) $ ULam lam
     where UPatAnn (WithSrcB pos' _) _ = b
           lam = ULamExpr arr b $ buildLam bs body

-- TODO Does this generalize?  Swap list for Nest?
buildFor :: SrcPos -> Direction -> [UPatAnn VoidS VoidS] -> UExpr VoidS -> UExpr VoidS
buildFor pos dir binders body = case binders of
  [] -> body
  b:bs -> WithSrcE (Just pos) $ UFor dir $ UForExpr b $ buildFor pos dir bs body

uViewExpr :: Parser (UExpr VoidS)
uViewExpr = do
  keyWord ViewKW
  bs <- some patAnn
  argTerm
  body <- blockOrExpr
  return $ buildLam (zipWith UPatAnnArrow bs (repeat TabArrow)) body

uForExpr :: Parser (UExpr VoidS)
uForExpr = do
  ((dir, trailingUnit), pos) <- withPos $
          (keyWord ForKW  $> (Fwd, False))
      <|> (keyWord For_KW $> (Fwd, True ))
      <|> (keyWord RofKW  $> (Rev, False))
      <|> (keyWord Rof_KW $> (Rev, True ))
  e <- buildFor pos dir <$> (some patAnn <* argTerm) <*> blockOrExpr
  if trailingUnit
    then return $ ns $ UDecl $ UDeclExpr (ULet PlainLet (UPatAnn (nsB UPatIgnore) Nothing) e) $
                                 ns unitExpr
    else return e

unitExpr :: UExpr' VoidS
unitExpr = UPrimExpr $ ConExpr $ ProdCon []

ns :: (a n) -> WithSrcE a n
ns = WithSrcE Nothing

nsB :: (b n l) -> WithSrcB b n l
nsB = WithSrcB Nothing

blockOrExpr :: Parser (UExpr VoidS)
blockOrExpr =  block <|> expr

unitCon :: Parser (UExpr VoidS)
unitCon = withSrc $ symbol "()" $> unitExpr

uTabCon :: Parser (UExpr VoidS)
uTabCon = withSrc $ do
  xs <- brackets $ expr `sepBy` sym ","
  return $ UTabCon xs

type UStatement (n::S) (l::S) = (EitherB UDecl (LiftB UExpr) n l, SrcPos)

block :: Parser (UExpr VoidS)
block = withIndent $ do
  statements <- mayNotBreak $ uStatement `sepBy1` (semicolon <|> try nextLine)
  case last statements of
    (LeftB _, _) -> fail "Last statement in a block must be an expression."
    _            -> return $ wrapUStatements statements

-- TODO Generalize to Nest UStatement n l -> UExpr n ?
wrapUStatements :: [UStatement VoidS VoidS] -> UExpr VoidS
wrapUStatements statements = case statements of
  [(RightB (LiftB e), _)] -> e
  (s, pos):rest -> WithSrcE (Just pos) $ case s of
    LeftB  d -> UDecl $ UDeclExpr d $ wrapUStatements rest
    RightB (LiftB e) -> UDecl $ UDeclExpr d $ wrapUStatements rest
      where d = ULet PlainLet (UPatAnn (nsB UPatIgnore) Nothing) e
    _ -> error "impossible"
  [] -> error "Shouldn't be reachable"

uStatement :: Parser (UStatement VoidS VoidS)
uStatement = withPos $   liftM LeftB  (instanceDef True <|> decl)
                     <|> liftM (RightB . LiftB) expr

-- TODO: put the `try` only around the `x:` not the annotation itself
uPiType :: Parser (UExpr VoidS)
uPiType = withSrc $ upi <$> piBinderPat <*> arrow effects <*> uType
  where
    upi binder (arr, eff) ty = UPi $ UPiExpr arr binder (fromMaybe Pure eff) ty
    piBinderPat :: Parser (UPatAnn VoidS VoidS)
    piBinderPat = do
      UAnnBinder b ty@(WithSrcE pos _) <- annBinder
      return case b of
        UBindSource n -> (UPatAnn (WithSrcB pos (fromString n))       (Just ty))
        UIgnore       -> (UPatAnn (WithSrcB pos (UPatBinder UIgnore)) (Just ty))
        UBind _       -> error "Shouldn't have UBind at parsing stage"

annBinder :: Parser (UAnnBinder (c::C) VoidS VoidS)
annBinder = try $ namedBinder <|> anonBinder

namedBinder :: Parser (UAnnBinder (c::C) VoidS VoidS)
namedBinder = label "named annoted binder" $ do
  v <- lowerName
  ty <- annot containedExpr
  return $ UAnnBinder (fromString v) ty

anonBinder :: Parser (UAnnBinder (s::C) VoidS VoidS)
anonBinder =
  label "anonymous annoted binder" $ UAnnBinder UIgnore <$>
    (underscore >> sym ":" >> containedExpr)

arrow :: Parser eff -> Parser (Arrow, Maybe eff)
arrow p =   (sym "->"  >> liftM ((PlainArrow,) . Just) p)
        <|> (sym "=>"  $> (TabArrow, Nothing))
        <|> (sym "--o" $> (LinArrow, Nothing))
        <|> (sym "?->" $> (ImplicitArrow, Nothing))
        <|> (sym "?=>" $> (ClassArrow, Nothing))
        <?> "arrow"

bareArrow :: Parser Arrow
bareArrow = fst <$> arrow (return ())

caseExpr :: Parser (UExpr VoidS)
caseExpr = withSrc $ do
  keyWord CaseKW
  e <- expr
  keyWord OfKW
  alts <- onePerLine $ UAlt <$> pat <*> (sym "->" *> blockOrExpr)
  return $ UCase e alts

ifExpr :: Parser (UExpr VoidS)
ifExpr = withSrc $ do
  keyWord IfKW
  e <- expr
  (alt1, maybeAlt2) <- oneLineThenElse <|> blockThenElse
  let alt2 = case maybeAlt2 of
        Nothing  -> ns unitExpr
        Just alt -> alt
  return $ UCase e
      [ UAlt (nsB $ UPatCon "True"  Empty)  alt1
      , UAlt (nsB $ UPatCon "False" Empty) alt2]

oneLineThenElse :: Parser (UExpr VoidS, Maybe (UExpr VoidS))
oneLineThenElse = do
  keyWord ThenKW
  alt1 <- eitherP block expr
  case alt1 of
    Left  e -> return (e, Nothing)
    Right e -> do
      alt2 <- optional $ keyWord ElseKW >> blockOrExpr
      return (e, alt2)

blockThenElse :: Parser (UExpr VoidS, Maybe (UExpr VoidS))
blockThenElse = withIndent $ mayNotBreak $ do
  alt1 <- keyWord ThenKW >> blockOrExpr
  alt2 <- optional $ do
    try $ nextLine >> keyWord ElseKW
    blockOrExpr
  return (alt1, alt2)

onePerLine :: Parser a -> Parser [a]
onePerLine p =   liftM (:[]) p
             <|> (withIndent $ mayNotBreak $ p `sepBy1` try nextLine)

pat :: Parser (UPat VoidS VoidS)
pat = mayNotPair $ makeExprParser leafPat patOps

leafPat :: Parser (UPat VoidS VoidS)
leafPat =
      (withSrcB (symbol "()" $> (UPatUnit UnitB)))
  <|> parens (mayPair $ makeExprParser leafPat patOps)
  <|> (withSrcB $
          (UPatBinder <$>  (   (fromString <$> lowerName)
                           <|> (underscore $> UIgnore)))
      <|> (UPatCon    <$> (fromString <$> upperName) <*> manyNested pat)
      <|> (variantPat `fallBackTo` recordPat)
      <|> brackets (UPatTable <$> toNestParsed <$> leafPat `sepBy` sym ",")
  )
  where pun pos l = WithSrcB (Just pos) $ fromString l
        def pos = WithSrcB (Just pos) $ UPatIgnore
        variantPat = parseVariant leafPat UPatVariant UPatVariantLift
        recordPat = unzipUPatRecord
                    <$> parseLabeledItems "," "=" leafPat (Just pun) (Just def)
        unzipUPatRecord :: ExtLabeledItems (UPat VoidS VoidS) (UPat VoidS VoidS)
                        -> UPat' VoidS VoidS
        unzipUPatRecord labeled = UPatRecord labels nest where
          (labels, items, rest) = unzipExtLabeledItems labeled
          nest = toNestParsed $ items ++ toList rest

-- TODO: add user-defined patterns
patOps :: [[Operator Parser (UPat VoidS VoidS)]]
patOps = [[InfixR patPairOp]]

patPairOp :: Parser (UPat (n::S) (l::S) -> UPat l (l'::S) -> UPat n l')
patPairOp = do
  allowed <- asks canPair
  if allowed
    then sym "," $> \x y -> joinSrcB x y $ UPatPair $ PairB x y
    else fail "pair pattern not allowed outside parentheses"

annot :: Parser a -> Parser a
annot p = label "type annotation" $ sym ":" >> p

patAnn :: Parser (UPatAnn VoidS VoidS)
patAnn = label "pattern" $ UPatAnn <$> pat <*> optional (annot containedExpr)

uPrim :: Parser (UExpr VoidS)
uPrim = withSrc $ do
  s <- primName
  case s of
    "ffi" -> do
      f <- lexeme $ some nameTailChar
      retTy <- leafExpr
      args <- some leafExpr
      return $ UPrimExpr $ OpExpr $ FFICall f retTy args
    _ -> case strToPrimName s of
      Just prim -> UPrimExpr <$> traverse (const leafExpr) prim
      Nothing -> fail $ "Unrecognized primitive: " ++ s

uVariantExpr :: Parser (UExpr VoidS)
uVariantExpr = withSrc $ parseVariant expr UVariant UVariantLift

parseVariant :: Parser a -> (LabeledItems () -> Label -> a -> b) -> (LabeledItems () -> a -> b) -> Parser b
parseVariant subparser buildLabeled buildExt =
  bracketed (symbol "{|") (symbol "|}") $ do
    let parseInactive = try $ fieldLabel <* notFollowedBy (symbol "=")
    inactiveLabels <- parseInactive `endBy1` (symbol "|") <|> pure []
    let inactiveItems = foldr (<>) NoLabeledItems $ map (flip labeledSingleton ()) inactiveLabels
    let parseLabeled = do l <- fieldLabel
                          symbol "="
                          buildLabeled inactiveItems l <$> subparser
    let parseExt = do symbol "..."
                      buildExt inactiveItems <$> subparser
    parseLabeled <|> parseExt

uLabeledExprs :: Parser (UExpr VoidS)
uLabeledExprs = withSrc $
    (URecord <$> build "," "=" (Just varPun) Nothing)
    `fallBackTo` (URecordTy <$> build "&" ":" Nothing Nothing)
    `fallBackTo` (UVariantTy <$> build "|" ":" Nothing Nothing)
  where build sep bindwith = parseLabeledItems sep bindwith expr

varPun :: SrcPos -> Label -> (UExpr VoidS)
varPun pos str = WithSrcE (Just pos) $ UVar (fromString str)

uDoSugar :: Parser (UExpr VoidS)
uDoSugar = withSrc $ do
  keyWord DoKW
  body <- blockOrExpr
  return $ ULam $ ULamExpr PlainArrow (UPatAnn (nsB $ UPatUnit UnitB) Nothing) body

uIsoSugar :: Parser (UExpr VoidS)
uIsoSugar = withSrc (char '#' *> options) where
  options = (recordFieldIso <$> fieldLabel)
            <|> char '?' *> (variantFieldIso <$> fieldLabel)
            <|> char '&' *> (recordZipIso <$> fieldLabel)
            <|> char '|' *> (variantZipIso <$> fieldLabel)
  plain = PlainArrow
  -- Explicitly specify types for `lam` and `alt` to prevent
  -- ambiguous type variable errors referring to the inner scopes
  -- defined thereby.
  lam :: UPat VoidS VoidS -> UExpr VoidS -> WithSrcE UExpr' VoidS
  lam p b = ns $ ULam $ ULamExpr plain (UPatAnn p Nothing) b
  alt :: UPat VoidS VoidS -> UExpr VoidS -> UAlt VoidS
  alt = UAlt
  recordFieldIso :: Label -> UExpr' VoidS
  recordFieldIso field =
    UApp plain (ns "MkIso") $
      ns $ URecord $ NoExt $
        labeledSingleton "fwd" (lam
          (nsB $ UPatRecord
                   (Ext (labeledSingleton field ()) (Just ()))
                   (toNest ["x", "r"]))
          $ (ns "(,)") `mkApp` (ns "x") `mkApp` (ns "r")
        )
        <> labeledSingleton "bwd" (lam
          (nsB $ UPatPair $ toPairB "x" "r")
          $ ns $ URecord $ Ext (labeledSingleton field $ "x")
                               $ Just $ "r"
        )
  variantFieldIso :: Label -> UExpr' VoidS
  variantFieldIso field =
    UApp plain "MkIso" $
      ns $ URecord $ NoExt $
        labeledSingleton "fwd" (lam "v" $ ns $ UCase "v"
            [ alt (nsB $ UPatVariant NoLabeledItems field "x")
                $ "Left" `mkApp` "x"
            , alt (nsB $ UPatVariantLift (labeledSingleton field ()) "r")
                $ "Right" `mkApp` "r"
            ]
        )
        <> labeledSingleton "bwd" (lam "v" $ ns $ UCase "v"
            [ alt (nsB $ UPatCon "Left" (toNest ["x"]))
                $ ns $ UVariant NoLabeledItems field $ "x"
            , alt (nsB $ UPatCon "Right" (toNest ["r"]))
                $ ns $ UVariantLift (labeledSingleton field ()) $ "r"
            ]
        )
  recordZipIso field =
    UApp plain "MkIso" $
      ns $ URecord $ NoExt $
        labeledSingleton "fwd" (lam
          (nsB $ UPatPair $ PairB
            (nsB $ UPatRecord (Ext NoLabeledItems $ Just $ ()) $ toNest ["l"])
            (nsB $ (UPatRecord (Ext (labeledSingleton field ()) $ Just ())
                               (toNest ["x", "r"]))))
          $ "(,)"
            `mkApp` (ns $ URecord $ (Ext (labeledSingleton field $ "x")
                                         $ Just $ "l"))
            `mkApp` (ns $ URecord $ Ext NoLabeledItems $ Just $ "r")
        )
        <> labeledSingleton "bwd" (lam
          (nsB $ UPatPair $ PairB
            (nsB $ (UPatRecord (Ext (labeledSingleton field ()) $ Just ())
                               (toNest ["x", "l"])))
            (nsB $ UPatRecord (Ext NoLabeledItems $ Just ()) $ toNest ["r"]))
          $ "(,)"
            `mkApp` (ns $ URecord $ Ext NoLabeledItems $ Just $ "l")
            `mkApp` (ns $ URecord $ Ext (labeledSingleton field $ "x")
                                        $ Just $ "r")
        )
  variantZipIso :: Label -> UExpr' VoidS
  variantZipIso field =
    UApp plain "MkIso" $
      ns $ URecord $ NoExt $
        labeledSingleton "fwd" (lam "v" $ ns $ UCase "v"
            [ alt (nsB $ UPatCon "Left" (toNest ["l"]))
                $ "Left" `mkApp` (ns $
                    UVariantLift (labeledSingleton field ()) $ "l")
            , alt (nsB $ UPatCon "Right" (toNest ["w"]))
                $ ns $ UCase "w"
                [ alt (nsB $ UPatVariant NoLabeledItems field "x")
                    $ "Left" `mkApp` (ns $
                        UVariant NoLabeledItems field $ "x")
                , alt (nsB $ UPatVariantLift (labeledSingleton field ()) "r")
                    $ "Right" `mkApp` "r"
                ]
            ]
        )
        <> labeledSingleton "bwd" (lam "v" $ ns $ UCase "v"
            [ alt (nsB $ UPatCon "Left" (toNest ["w"]))
                $ ns $ UCase "w"
                [ alt (nsB $ UPatVariant NoLabeledItems field "x")
                    $ "Right" `mkApp` (ns $
                        UVariant NoLabeledItems field $ "x")
                , alt (nsB $ UPatVariantLift (labeledSingleton field ())
                                             "r")
                    $ "Left" `mkApp` "r"
                ]
            , alt (nsB $ UPatCon "Right" (toNest ["l"]))
                $ "Right" `mkApp` (ns $
                    UVariantLift (labeledSingleton field ()) "l")
            ]
        )

parseLabeledItems
  :: String -> String -> Parser a
  -> Maybe (SrcPos -> Label -> a) -> Maybe (SrcPos -> a)
  -> Parser (ExtLabeledItems a a)
parseLabeledItems sep bindwith itemparser punner tailDefault =
  bracketed lBrace rBrace $ atBeginning
  where
    atBeginning = someItems
                  <|> (symbol sep >> (stopAndExtend <|> stopWithoutExtend))
                  <|> stopWithoutExtend
    stopWithoutExtend = return $ NoExt NoLabeledItems
    stopAndExtend = do
      ((), pos) <- withPos $ symbol "..."
      rest <- case tailDefault of
        Just def -> itemparser <|> pure (def pos)
        Nothing -> itemparser
      return $ Ext NoLabeledItems (Just rest)
    beforeSep = (symbol sep >> afterSep) <|> stopWithoutExtend
    afterSep = someItems <|> stopAndExtend <|> stopWithoutExtend
    someItems = do
      (l, pos) <- withPos fieldLabel
      let explicitBound = symbol bindwith *> itemparser
      itemVal <- case punner of
        Just punFn -> explicitBound <|> pure (punFn pos l)
        Nothing -> explicitBound
      rest <- beforeSep
      return $ prefixExtLabeledItems (labeledSingleton l itemVal) rest

-- Combine two parsers such that if the first fails, we try the second one.
-- If both fail, consume the same amount of input as the parser that
-- consumed the most input, and use its error message. Useful if you want
-- to parse multiple things, but they share some common starting symbol, and
-- you don't want the first one failing to prevent the second from succeeding.
-- Unlike using `try` and/or (<|>), if both parsers fail and either one consumes
-- input, parsing is aborted. Also, if both parsers consume the same amount of
-- input, we combine the symbols each was expecting.
fallBackTo :: Parser a -> Parser a -> Parser a
fallBackTo optionA optionB = do
  startState <- getParserState
  resA <- observing $ optionA
  case resA of
    Right val -> return val
    Left errA -> do
      stateA <- getParserState
      updateParserState $ const startState
      resB <- observing $ optionB
      case resB of
        Right val -> return val
        Left errB -> case compare (errorOffset errA) (errorOffset errB) of
          LT -> parseError errB
          GT -> updateParserState (const stateA) >> parseError errA
          EQ -> case (errA, errB) of
            -- Combine what each was expecting.
            (TrivialError offset unexpA expA, TrivialError _ unexpB expB)
                -> parseError $ TrivialError offset (unexpA <|> unexpB)
                                                    (expA <> expB)
            _ -> fail $ "Multiple failed parse attempts:\n"
                  <> parseErrorPretty errA <> "\n" <> parseErrorPretty errB

-- === infix ops ===

-- literal symbols here must only use chars from `symChars`
ops :: [[Operator Parser (UExpr VoidS)]]
ops =
  [ [InfixL $ sym "." $> mkGenApp TabArrow, symOp "!"]
  , [InfixL $ sc $> mkApp]
  , [prefixNegOp]
  , [anySymOp] -- other ops with default fixity
  , [symOp "+", symOp "-", symOp "||", symOp "&&",
     InfixR $ sym "=>" $> mkArrow TabArrow Pure,
     InfixL $ opWithSrc $ backquoteName >>= (return . binApp),
     symOp "<<<", symOp ">>>", symOp "<<&", symOp "&>>"]
  , [annotatedExpr]
  , [InfixR $ mayBreak (infixSym "$") $> mkApp]
  , [symOp "+=", symOp ":=", InfixL $ pairingSymOpP "|", InfixR infixArrow]
  , [InfixR $ pairingSymOpP "&", InfixR $ pairingSymOpP ","]
  , indexRangeOps
  ]

opWithSrc :: Parser (SrcPos -> a -> a -> a)
          -> Parser (a -> a -> a)
opWithSrc p = do
  (f, pos) <- withPos p
  return $ f pos

anySymOp :: Operator Parser (UExpr VoidS)
anySymOp = InfixL $ opWithSrc $ do
  s <- label "infix operator" (mayBreak anySym)
  return $ binApp s

infixSym :: SourceName -> Parser ()
infixSym s = mayBreak $ sym s

symOp :: SourceName -> Operator Parser (UExpr VoidS)
symOp s = InfixL $ symOpP s

symOpP :: SourceName -> Parser (UExpr VoidS -> UExpr VoidS -> UExpr VoidS)
symOpP s = opWithSrc $ do
  label "infix operator" (infixSym s)
  return $ binApp $ "(" <> s <> ")"

pairingSymOpP :: String -> Parser (UExpr VoidS -> UExpr VoidS -> UExpr VoidS)
pairingSymOpP s = opWithSrc $ do
  allowed <- asks canPair
  if allowed
    then infixSym s >> return (binApp (fromString $ "("<>s<>")"))
    else fail $ "Unexpected delimiter " <> s

prefixNegOp :: Operator Parser (UExpr VoidS)
prefixNegOp = Prefix $ label "negation" $ do
  ((), pos) <- withPos $ sym "-"
  let f = WithSrcE (Just pos) "neg"
  return \case
    -- Special case: negate literals directly
    WithSrcE litpos (IntLitExpr i)
      -> WithSrcE (joinPos (Just pos) litpos) (IntLitExpr (-i))
    WithSrcE litpos (FloatLitExpr i)
      -> WithSrcE (joinPos (Just pos) litpos) (FloatLitExpr (-i))
    x -> mkApp f x

binApp :: SourceName -> SrcPos -> UExpr VoidS -> UExpr VoidS -> UExpr VoidS
binApp f pos x y = (f' `mkApp` x) `mkApp` y
  where f' = WithSrcE (Just pos) $ fromString f

mkGenApp :: Arrow -> UExpr (n::S) -> UExpr n -> UExpr n
mkGenApp arr f x = joinSrc f x $ UApp arr f x

mkApp :: UExpr (n::S) -> UExpr n -> UExpr n
mkApp = mkGenApp PlainArrow

infixArrow :: Parser (UType VoidS -> UType VoidS -> UType VoidS)
infixArrow = do
  notFollowedBy (sym "=>")  -- table arrows have special fixity
  ((arr, eff), pos) <- withPos $ arrow effects
  return \a b -> WithSrcE (Just pos) $ UPi $ UPiExpr arr (UPatAnn (nsB UPatIgnore) (Just a)) (fromMaybe Pure eff) b

mkArrow :: Arrow -> UEffectRow VoidS -> UExpr VoidS -> UExpr VoidS -> UExpr VoidS
mkArrow arr eff a b = joinSrc a b $ UPi $ UPiExpr arr (UPatAnn (nsB UPatIgnore) (Just a)) eff b

withSrc :: Parser (a n) -> Parser (WithSrcE a n)
withSrc p = do
  (x, pos) <- withPos p
  return $ WithSrcE (Just pos) x

withSrcB :: Parser (b n l) -> Parser (WithSrcB b n l)
withSrcB p = do
  (x, pos) <- withPos p
  return $ WithSrcB (Just pos) x

joinSrc :: WithSrcE a1 n1 -> WithSrcE a2 n2 -> a3 n3 -> WithSrcE a3 n3
joinSrc (WithSrcE p1 _) (WithSrcE p2 _) x = WithSrcE (joinPos p1 p2) x

joinSrcB :: WithSrcB a1 n1 l1 -> WithSrcB a2 n2 l2 -> a3 n3 l3 -> WithSrcB a3 n3 l3
joinSrcB (WithSrcB p1 _) (WithSrcB p2 _) x = WithSrcB (joinPos p1 p2) x

joinPos :: Maybe SrcPos -> Maybe SrcPos -> Maybe SrcPos
joinPos Nothing p = p
joinPos p Nothing = p
joinPos (Just (l, h)) (Just (l', h')) = Just (min l l', max h h')

indexRangeOps :: [Operator Parser (UExpr VoidS)]
indexRangeOps =
  [ Prefix    $ symPos ".."   <&> \pos h   -> range pos  Unlimited       (InclusiveLim h)
  , inpostfix $ symPos ".."   <&> \pos l h -> range pos (InclusiveLim l) (limFromMaybe h)
  , inpostfix $ symPos "<.."  <&> \pos l h -> range pos (ExclusiveLim l) (limFromMaybe h)
  , Prefix    $ symPos "..<"  <&> \pos h   -> range pos  Unlimited       (ExclusiveLim h)
  , InfixL    $ symPos "..<"  <&> \pos l h -> range pos (InclusiveLim l) (ExclusiveLim h)
  , InfixL    $ symPos "<..<" <&> \pos l h -> range pos (ExclusiveLim l) (ExclusiveLim h) ]
  where
    range pos l h = WithSrcE (Just pos) $ UIndexRange l h
    symPos s = snd <$> withPos (sym s)

limFromMaybe :: Maybe a -> Limit a
limFromMaybe Nothing = Unlimited
limFromMaybe (Just x) = InclusiveLim x

annotatedExpr :: Operator Parser (UExpr VoidS)
annotatedExpr = InfixL $ opWithSrc $
  sym ":" $> (\pos v ty -> WithSrcE (Just pos) $ UTypeAnn v ty)

inpostfix :: Parser (UExpr VoidS -> Maybe (UExpr VoidS) -> UExpr VoidS)
          -> Operator Parser (UExpr VoidS)
inpostfix = inpostfix' expr

inpostfix' :: Parser a -> Parser (a -> Maybe a -> a) -> Operator Parser a
inpostfix' p op = Postfix $ do
  f <- op
  rest <- optional p
  return \x -> f x rest

-- === lexemes ===

-- These `Lexer` actions must be non-overlapping and never consume input on failure
type Lexer = Parser

data KeyWord = DefKW | ForKW | For_KW | RofKW | Rof_KW | CaseKW | OfKW
             | ReadKW | WriteKW | StateKW | DataKW | InterfaceKW
             | InstanceKW | WhereKW | IfKW | ThenKW | ElseKW | DoKW
             | ExceptKW | IOKW | ViewKW | ImportKW | NamedInstanceKW

upperName :: Lexer SourceName
upperName = label "upper-case name" $ lexeme $
  checkNotKeyword $ (:) <$> upperChar <*> many nameTailChar

lowerName  :: Lexer SourceName
lowerName = label "lower-case name" $ lexeme $
  checkNotKeyword $ (:) <$> lowerChar <*> many nameTailChar

anyCaseName  :: Lexer SourceName
anyCaseName = lowerName <|> upperName

anyName  :: Lexer SourceName
anyName = lowerName <|> upperName <|> symName

checkNotKeyword :: Parser String -> Parser String
checkNotKeyword p = try $ do
  s <- p
  failIf (s `elem` keyWordStrs) $ show s ++ " is a reserved word"
  return s

keyWord :: KeyWord -> Lexer ()
keyWord kw = lexeme $ try $ string s >> notFollowedBy nameTailChar
  where
    s = case kw of
      DefKW  -> "def"
      ForKW  -> "for"
      RofKW  -> "rof"
      For_KW  -> "for_"
      Rof_KW  -> "rof_"
      CaseKW -> "case"
      IfKW   -> "if"
      ThenKW -> "then"
      ElseKW -> "else"
      OfKW   -> "of"
      ReadKW  -> "Read"
      WriteKW -> "Accum"
      StateKW -> "State"
      ExceptKW -> "Except"
      IOKW     -> "IO"
      DataKW -> "data"
      InterfaceKW -> "interface"
      InstanceKW -> "instance"
      NamedInstanceKW -> "named-instance"
      WhereKW -> "where"
      DoKW   -> "do"
      ViewKW -> "view"
      ImportKW -> "import"

keyWordStrs :: [String]
keyWordStrs = ["def", "for", "for_", "rof", "rof_", "case", "of", "llam",
               "Read", "Write", "Accum", "Except", "IO", "data", "interface",
               "instance", "named-instance", "where", "if", "then", "else", "do", "view", "import"]

fieldLabel :: Lexer Label
fieldLabel = label "field label" $ lexeme $
  checkNotKeyword $ (:) <$> (lowerChar <|> upperChar) <*> many nameTailChar

primName :: Lexer String
primName = lexeme $ try $ char '%' >> some alphaNumChar

charLit :: Lexer Char
charLit = lexeme $ char '\'' >> L.charLiteral <* char '\''

strLit :: Lexer String
strLit = lexeme $ char '"' >> manyTill L.charLiteral (char '"')

intLit :: Lexer Int
intLit = lexeme $ try $ L.decimal <* notFollowedBy (char '.')

doubleLit :: Lexer Double
doubleLit = lexeme $
      try L.float
  <|> try (fromIntegral <$> (L.decimal :: Parser Int) <* char '.')

knownSymStrs :: [String]
knownSymStrs = [".", ":", "!", "=", "-", "+", "||", "&&", "$", "&", "|", ",", "+=", ":=",
                "->", "=>", "?->", "?=>", "--o", "--", "<<<", ">>>", "<<&", "&>>",
                "..", "<..", "..<", "..<", "<..<"]

-- string must be in `knownSymStrs`
sym :: String -> Lexer ()
sym s = lexeme $ try $ string s >> notFollowedBy symChar

anySym :: Lexer String
anySym = lexeme $ try $ do
  s <- some symChar
  -- TODO: consider something faster than linear search here
  failIf (s `elem` knownSymStrs) ""
  return $ "(" <> s <> ")"

symName :: Lexer SourceName
symName = label "symbol name" $ lexeme $ try $ do
  s <- between (char '(') (char ')') $ some symChar
  return $ "(" <> s <> ")"

backquoteName :: Lexer SourceName
backquoteName = label "backquoted name" $
  lexeme $ try $ between (char '`') (char '`') (upperName <|> lowerName)

-- brackets and punctuation
-- (can't treat as sym because e.g. `((` is two separate lexemes)
lParen, rParen, lBracket, rBracket, lBrace, rBrace, semicolon, underscore :: Lexer ()

lParen    = notFollowedBy symName >> notFollowedBy unitCon >> charLexeme '('
rParen    = charLexeme ')'
lBracket  = charLexeme '['
rBracket  = charLexeme ']'
lBrace    = charLexeme '{'
rBrace    = charLexeme '}'
semicolon = charLexeme ';'
underscore = charLexeme '_'

charLexeme :: Char -> Parser ()
charLexeme c = void $ lexeme $ char c

nameTailChar :: Parser Char
nameTailChar = alphaNumChar <|> char '\'' <|> char '_'

symChar :: Parser Char
symChar = choice $ map char symChars

symChars :: [Char]
symChars = ".,!$^&*:-~+/=<>|?\\@"

-- === Util ===

runTheParser :: String -> Parser a -> Either (ParseErrorBundle String Void) a
runTheParser s p = parse (runReaderT p (ParseCtx 0 False False)) "" s

sc :: Parser ()
sc = L.space space lineComment empty

lineComment :: Parser ()
lineComment = do
  try $ string "--" >> notFollowedBy (void (char 'o'))
  void (takeWhileP (Just "char") (/= '\n'))

emptyLines :: Parser ()
emptyLines = void $ many (sc >> eol)

outputLines :: Parser ()
outputLines = void $ many (symbol ">" >> takeWhileP Nothing (/= '\n') >> ((eol >> return ()) <|> eof))

stringLiteral :: Parser String
stringLiteral = char '"' >> manyTill L.charLiteral (char '"') <* sc

space :: Parser ()
space = do
  consumeNewLines <- asks canBreak
  if consumeNewLines
    then space1
    else void $ takeWhile1P (Just "white space") (`elem` (" \t" :: String))

mayBreak :: Parser a -> Parser a
mayBreak p = local (\ctx -> ctx { canBreak = True }) p

mayNotBreak :: Parser a -> Parser a
mayNotBreak p = local (\ctx -> ctx { canBreak = False }) p

mayPair :: Parser a -> Parser a
mayPair p = local (\ctx -> ctx { canPair = True }) p

mayNotPair :: Parser a -> Parser a
mayNotPair p = local (\ctx -> ctx { canPair = False }) p

optionalMonoid :: Monoid a => Parser a -> Parser a
optionalMonoid p = p <|> return mempty

nameString :: Parser String
nameString = lexeme . try $ (:) <$> lowerChar <*> many alphaNumChar

thisNameString :: String -> Parser ()
thisNameString s = lexeme $ try $ string s >> notFollowedBy alphaNumChar

uint :: Parser Int
uint = L.decimal <* sc

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: String -> Parser ()
symbol s = void $ L.symbol sc s

argTerm :: Parser ()
argTerm = mayNotBreak $ sym "."

bracketed :: Parser () -> Parser () -> Parser a -> Parser a
bracketed left right p = between left right $ mayBreak $ sc >> p

parens :: Parser a -> Parser a
parens p = bracketed lParen rParen p

brackets :: Parser a -> Parser a
brackets p = bracketed lBracket rBracket p

braces :: Parser a -> Parser a
braces p = bracketed lBrace rBrace p

manyNested :: Parser (a VoidS VoidS) -> Parser (Nest a VoidS VoidS)
manyNested p = toNestParsed <$> many p

withPos :: Parser a -> Parser (a, SrcPos)
withPos p = do
  n <- getOffset
  x <- p
  n' <- getOffset
  return $ (x, (n, n'))

nextLine :: Parser ()
nextLine = do
  eol
  n <- asks curIndent
  void $ mayNotBreak $ many $ try (sc >> eol)
  void $ replicateM n (char ' ')

withSource :: Parser a -> Parser (String, a)
withSource p = do
  s <- getInput
  (x, (start, end)) <- withPos p
  return (take (end - start) s, x)

withIndent :: Parser a -> Parser a
withIndent p = do
  nextLine
  indent <- liftM length $ some (char ' ')
  local (\ctx -> ctx { curIndent = curIndent ctx + indent }) $ p

eol :: Parser ()
eol = void MC.eol

eolf :: Parser ()
eolf = eol <|> eof

failIf :: Bool -> String -> Parser ()
failIf True s = fail s
failIf False _ = return ()

_debug :: Show a => String -> Parser a -> Parser a
_debug s m = mapReaderT (Text.Megaparsec.Debug.dbg s) m
