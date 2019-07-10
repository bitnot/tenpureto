module Tenpureto.Graph
    ( Graph
    , overlay
    , compose
    , vertex
    , vertices
    , edge
    , edges
    , path
    , mapVertices
    , filterVertices
    , filterMapVertices
    , graphRoots
    , foldTopologically
    , GraphSubsetDecision(..)
    , graphSubset
    , graphAncestors
    )
where

import           Data.Maybe
import qualified Data.Set                      as Set
import qualified Data.Map                      as Map
import qualified Algebra.Graph                 as G
import           Algebra.Graph.ToGraph          ( ToVertex
                                                , ToGraph
                                                , toGraph
                                                , toAdjacencyMap
                                                , toAdjacencyMapTranspose
                                                , adjacencyMap
                                                , dfs
                                                )
import qualified Algebra.Graph.NonEmpty.AdjacencyMap
                                               as NAM
import           Data.List.NonEmpty             ( NonEmpty(..) )
import           Algebra.Graph.AdjacencyMap.Algorithm
                                                ( scc )
import           Data.Functor
import           Data.Functor.Identity
import           Control.Monad

data Graph a = Graph { unGraph :: G.Graph a, graphNormalized :: G.Graph a }
    deriving (Show)

instance Ord a => Eq (Graph a) where
    x == y = toGraph x == toGraph y

instance Ord a => ToGraph (Graph a) where
    type ToVertex (Graph a) = a
    toGraph = graphNormalized

graph :: Ord a => G.Graph a -> Graph a
graph a = Graph a (normalize a)

overlay :: Ord a => Graph a -> Graph a -> Graph a
overlay x y = graph $ G.overlay (unGraph x) (unGraph y)

compose :: Ord a => Graph a -> Graph a -> Graph a
compose x y = graph $ G.compose (unGraph x) (unGraph y)

vertex :: Ord a => a -> Graph a
vertex = graph . G.vertex

vertices :: Ord a => [a] -> Graph a
vertices = graph . G.vertices

edge :: Ord a => a -> a -> Graph a
edge x y = graph $ G.edge x y

edges :: Ord a => [(a, a)] -> Graph a
edges = graph . G.edges

path :: Ord a => [a] -> Graph a
path = graph . G.path

mapVertices :: (Ord a, Ord b) => (a -> b) -> Graph a -> Graph b
mapVertices f = graph . fmap f . unGraph

filterVertices :: Ord a => (a -> Bool) -> Graph a -> Graph a
filterVertices f = filterMapVertices (\x -> if f x then Just x else Nothing)

filterMapVertices :: (Ord a, Ord b) => (a -> Maybe b) -> Graph a -> Graph b
filterMapVertices f x =
    graph $ (=<<) (maybe G.empty G.vertex . snd) $ filterEmptyVertices $ fmap
        zipf
        (unGraph x)
  where
    zipf z = (z, f z)
    removeIfEmpty (  _, Just _ ) acc = acc
    removeIfEmpty v@(_, Nothing) acc = removeVertexConnecting v acc
    filterEmptyVertices
        :: (Ord a, Ord b) => G.Graph (a, Maybe b) -> G.Graph (a, Maybe b)
    filterEmptyVertices g = foldr removeIfEmpty g (G.vertexList g)
    removeVertexConnecting v g =
        let ctx = G.context (v ==) g
            cct c = G.connect (G.vertices (G.inputs c))
                              (G.vertices (G.outputs c))
            g' = G.removeVertex v g
        in  maybe g' (G.overlay g' . cct) ctx

graphLeaves :: Ord a => Graph a -> [a]
graphLeaves =
    Set.toList
        . Map.keysSet
        . Map.filter Set.null
        . adjacencyMap
        . toAdjacencyMap

graphRoots :: Ord a => Graph a -> [a]
graphRoots =
    Set.toList
        . Map.keysSet
        . Map.filter Set.null
        . adjacencyMap
        . toAdjacencyMapTranspose

graphAncestors :: Ord a => Graph a -> [a] -> [a]
graphAncestors g vs =
    let transposed = toAdjacencyMapTranspose g in dfs vs transposed

foldTopologically
    :: (Ord a, Monad m)
    => (a -> [b] -> m b)
    -> (b -> b -> m b)
    -> Graph a
    -> m (Maybe b)
foldTopologically vcombine hcombine g =
    let leaves  = graphLeaves g
        parents = adjacencyMap (toAdjacencyMapTranspose g)
        parent  = maybe mempty Set.toList . flip Map.lookup parents
        foldVertex v = do
            pbs <- traverse foldVertex (parent v)
            vcombine v pbs
    in  foldMaybeM hcombine =<< traverse foldVertex leaves

data GraphSubsetDecision = MustDrop | PreferDrop | PreferKeep | MustKeep
    deriving (Show, Eq, Ord, Enum, Bounded)

graphSubset :: Ord a => (a -> GraphSubsetDecision) -> Graph a -> Graph a
graphSubset f g = runIdentity $ do
    (must, _) <-
        fromMaybe (mempty, Nothing) <$> foldTopologically vcombine hcombine g
    return $ filterVertices (`Set.member` must) g
  where
    vcombine c ps = return $ case f c of
        MustDrop   -> (must, Nothing)
        PreferDrop -> (must, fmap (Set.insert c) may)
        PreferKeep -> (must <> maybe mempty (Set.insert c) may, may $> mempty)
        MustKeep   -> (Set.insert c must <> fromMaybe mempty may, Just mempty)
      where
        must = foldMap fst ps
        may  = fmap mconcat (traverse snd ps)
    hcombine (xmust, xmay) (ymust, ymay) =
        return (xmust <> ymust, xmay <> ymay)

-- Internal

filterEdges :: Ord a => ((a, a) -> Bool) -> G.Graph a -> G.Graph a
filterEdges predicate x = G.overlay
    (G.vertices $ G.vertexList x)
    (G.edges $ filter predicate (G.edgeList x))

removeLoops :: Ord a => G.Graph a -> G.Graph a
removeLoops = filterEdges (uncurry (/=))

subtractEdges :: Ord a => G.Graph a -> G.Graph a -> G.Graph a
subtractEdges x y =
    let yEdges   = G.edgeSet y
        yhasEdge = flip Set.member yEdges
    in  filterEdges (not . yhasEdge) x

removeTransitiveEdges :: Ord a => G.Graph a -> G.Graph a
removeTransitiveEdges g = g `subtractEdges` (recCompose (g `G.compose` g))
  where
    recCompose x =
        let y = G.overlay x (x `G.compose` g)
        in  if y == x then y else recCompose y

dropCycles :: Ord a => G.Graph a -> G.Graph a
dropCycles = (>>= vertexOrEmpty) . toGraph . scc . toAdjacencyMap
  where
    vertexOrEmpty cc = case NAM.vertexList1 cc of
        v :| [] -> G.vertex v
        _       -> G.empty

normalize :: Ord a => G.Graph a -> G.Graph a
normalize = removeTransitiveEdges . dropCycles . removeLoops

foldMaybeM :: (Monad m, Traversable t) => (a -> a -> m a) -> t a -> m (Maybe a)
foldMaybeM combine = foldM combine' Nothing
  where
    combine' Nothing  x = Just <$> return x
    combine' (Just x) y = Just <$> combine x y
