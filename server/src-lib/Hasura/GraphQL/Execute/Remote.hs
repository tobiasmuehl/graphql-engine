module Hasura.GraphQL.Execute.Remote
  ( buildExecStepRemote
  , collectVariablesFromSelectionSet
  , collectVariables
  , resolveRemoteVariable
  , resolveRemoteField
  , runVariableCache
  ) where

import           Hasura.Prelude

import qualified Data.Aeson                             as J
import qualified Data.HashMap.Strict                    as Map
import qualified Data.HashSet                           as Set
import qualified Data.Text                              as T
import qualified Language.GraphQL.Draft.Syntax          as G

import           Data.Text.Extended

import qualified Hasura.GraphQL.Transport.HTTP.Protocol as GH

import           Hasura.Base.Error
import           Hasura.GraphQL.Execute.Backend
import           Hasura.GraphQL.Parser
import           Hasura.GraphQL.Transport.HTTP.Protocol
import           Hasura.RQL.Types
import           Hasura.Session


mkVariableDefinitionAndValue :: Variable -> (G.VariableDefinition, (G.Name, J.Value))
mkVariableDefinitionAndValue var@(Variable varInfo gType varValue) =
  (varDefn, (varName, varJSONValue))
  where
    varName = getName var

    varDefn = G.VariableDefinition varName gType defaultVal

    defaultVal =
      case varInfo of
        VIRequired _     -> Nothing
        VIOptional _ val -> Just val

    varJSONValue =
      case varValue of
        JSONValue v      -> v
        GraphQLValue val -> graphQLValueToJSON val

unresolveVariables
  :: forall fragments
   . Functor fragments
  => G.SelectionSet fragments Variable
  -> G.SelectionSet fragments G.Name
unresolveVariables =
  fmap (fmap (getName . vInfo))

collectVariables
  :: forall fragments var
   . (Foldable fragments, Hashable var, Eq var)
  => G.SelectionSet fragments var
  -> Set.HashSet var
collectVariables =
  Set.unions . fmap (foldMap Set.singleton)

collectVariablesFromSelectionSet
  :: G.SelectionSet G.NoFragments Variable
  -> [(G.VariableDefinition, (G.Name, J.Value))]
collectVariablesFromSelectionSet =
  map mkVariableDefinitionAndValue . Set.toList . collectVariables


buildExecStepRemote
  :: RemoteSchemaInfo
  -> RemoteResultCustomizer
  -> G.OperationType
  -> G.SelectionSet G.NoFragments Variable
  -> ExecutionStep
buildExecStepRemote remoteSchemaInfo resultCustomizer tp selSet =
  let unresolvedSelSet = unresolveVariables selSet
      allVars = map mkVariableDefinitionAndValue $ Set.toList $ collectVariables selSet
      varValues = Map.fromList $ map snd allVars
      varValsM = bool (Just varValues) Nothing $ Map.null varValues
      varDefs = map fst allVars
      _grQuery = G.TypedOperationDefinition tp Nothing varDefs [] unresolvedSelSet
      _grVariables = varValsM
  in ExecStepRemote remoteSchemaInfo resultCustomizer GH.GQLReq{_grOperationName = Nothing, ..}


-- | resolveRemoteVariable resolves a `RemoteSchemaVariable` into a GraphQL `Variable`. A
-- `RemoteSchemaVariable` can either be a query variable i.e. variable provided in the
-- query or it can be a `SessionPresetVariable` in which case we look up the value of the
-- session variable and coerce it into the appropriate type and then construct the GraphQL
-- `Variable`. *NOTE*: The session variable preset is a hard preset i.e. if the session
-- variable doesn't exist, an error will be thrown.
--
-- The name of the GraphQL variable generated will be a GraphQL-ized (replacing '-' by
-- '_') version of the session variable, since session variables are not valid GraphQL
-- names.
--
-- Additionally, we need to handle partially traversed JSON values; likewise, we create a
-- new variable out of thin air.
--
--
-- For example, considering the following schema for a role:
--
--   input UserName {
--     firstName : String! @preset(value:"Foo")
--     lastName  : String!
--   }
--
--   type Query {
--     user(
--       user_id:   Int! @preset(value:"x-hasura-user-id")
--       user_name: UserName!
--     ): User
--   }
--
-- and the incoming query to the graphql-engine is:
--
--   query($foo: UserName!) {
--     user(user_name: $foo) { id name }
--   }
--
-- with variables:
--
--   { "foo": {"lastName": "Bar"} }
--
--
-- After resolving the session argument presets, the query that will be sent to the remote
-- server will be:
--
-- query ($x_hasura_user_id: Int!, $hasura_json_var_1: String!) {
--   user (user_id: $x_hasura_user_id, user_name: {firstName: "Foo", lastName: $hasura_json_var_1}) {
--     id
--     name
--   }
-- }
--
resolveRemoteVariable
  :: (MonadError QErr m)
  => UserInfo
  -> RemoteSchemaVariable
  -> StateT (HashMap J.Value Int) m Variable
resolveRemoteVariable userInfo = \case
  SessionPresetVariable sessionVar typeName presetInfo -> do
    sessionVarVal <- onNothing (getSessionVariableValue sessionVar $ _uiSession userInfo)
      $ throw400 NotFound $ sessionVar <<> " session variable expected, but not found"
    let varName = sessionVariableToGraphQLName sessionVar
    coercedValue <-
      case presetInfo of
        SessionArgumentPresetScalar ->
          case G.unName typeName of
            "Int" ->
              case readMaybe $ T.unpack sessionVarVal of
                Nothing -> throw400 CoercionError $ sessionVarVal <<> " cannot be coerced into an Int value"
                Just i -> pure $ G.VInt i
            "Boolean" ->
              if | sessionVarVal `elem` ["true", "false"] ->
                   pure $ G.VBoolean $ "true" == sessionVarVal
                 | otherwise ->
                   throw400 CoercionError $ sessionVarVal <<> " cannot be coerced into a Boolean value"
            "Float" ->
               case readMaybe $ T.unpack sessionVarVal of
                 Nothing ->
                   throw400 CoercionError $ sessionVarVal <<> " cannot be coerced into a Float value"
                 Just i -> pure $ G.VFloat i
            -- The `String`,`ID` and the default case all use the same code. But,
            -- it will be better to not merge all of them into the default case
            -- because it will be helpful to know how all the built-in scalars
            -- are handled
            "String" -> pure $ G.VString sessionVarVal
            "ID" -> pure $ G.VString sessionVarVal
            -- When we encounter a custom scalar, we just pass it as a string
            _ -> pure $ G.VString sessionVarVal
        SessionArgumentPresetEnum enumVals -> do
          sessionVarEnumVal <-
            G.EnumValue <$>
              onNothing
                (G.mkName sessionVarVal)
                (throw400 CoercionError $ sessionVarVal <<> " is not a valid GraphQL name")
          case sessionVarEnumVal `Set.member` enumVals of
            True  -> pure $ G.VEnum sessionVarEnumVal
            False -> throw400 CoercionError $ sessionVarEnumVal <<> " is not one of the valid enum values"
    -- nullability is false, because we treat presets as hard presets
    let variableGType = G.TypeNamed (G.Nullability False) typeName
    pure $ Variable (VIRequired varName) variableGType (GraphQLValue coercedValue)
  RemoteJSONValue gtype jsonValue -> do
    cache <- get
    index <- Map.lookup jsonValue cache `onNothing` do
      let i = Map.size cache + 1
      put $ Map.insert jsonValue i cache
      pure i
    let varName = G.unsafeMkName $ "hasura_json_var_" <> tshow index
    pure $ Variable (VIRequired varName) gtype $ JSONValue jsonValue
  QueryVariable variable -> pure variable

resolveRemoteField
  :: (MonadError QErr m, Traversable f)
  => UserInfo
  -> RemoteFieldG f RemoteSchemaVariable
  -> StateT (HashMap J.Value Int) m (RemoteFieldG f Variable)
resolveRemoteField userInfo = traverse (resolveRemoteVariable userInfo)

runVariableCache
  :: Monad m
  => StateT (HashMap J.Value Int) m a
  -> m a
runVariableCache = flip evalStateT mempty
