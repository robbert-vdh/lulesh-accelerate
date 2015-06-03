{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RebindableSyntax    #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
--
-- This module contains the main implementation of the Livermore Unstructured
-- Lagrangian Explicit Shock Hydrodynamics (LULESH) mini-app in Accelerate.
--
-- NOTES:
--
-- Most functions are named similarly to the corresponding function in the
-- reference C implementation.
--
-- I did my best to add comments as I reverse-engineered the C code, but I
-- apologise that it may be difficult to understand.
--
module LULESH where

import Domain
import Type
import Util

import Prelude                                          as P hiding ( (<*) )
import Data.Array.Accelerate                            as A hiding ( transpose )
import Data.Array.Accelerate.Linear                     as L hiding ( Epsilon )
import Data.Array.Accelerate.Control.Lens               as L hiding ( _1, _2, _3, _4, _5, _6, _7, _8, _9, at, ix, use )


-- Lagrange Leapfrog Algorithm
-- ===========================

-- | 'lagrangeLeapFrog' advances the solution from t_n to t_{n+1} over the time
-- increment delta_t. The process of advance the solution is comprised of two
-- major parts:
--
--   1. Advance variables on the nodal mesh; and
--   2. Advance the element variables
--
lagrangeLeapFrog
    :: Parameters
    -> Exp Time
    -> Acc (Field Position)
    -> Acc (Field Velocity)
    -> Acc (Field Energy)
    -> Acc (Field Pressure)
    -> Acc (Field Viscosity)
    -> Acc (Field Volume)       -- relative volume
    -> Acc (Field Volume)       -- reference volume
    -> Acc (Field R)            -- speed of sound
    -> Acc (Field Mass)         -- element mass
    -> Acc (Field Mass)         -- nodal mass
    -> ( Acc (Field Position)
       , Acc (Field Velocity)
       , Acc (Field Energy)
       , Acc (Field Pressure)
       , Acc (Field Viscosity)
       , Acc (Field Volume)
       , Acc (Field R)
       , Acc (Scalar Time)
       , Acc (Scalar Time) )
lagrangeLeapFrog param dt x dx e p q v v0 ss mZ mN =
  let
      -- Calculate nodal quantities
      (x', dx')
          = lagrangeNodal param dt x dx p q v v0 ss mZ mN

      -- Calculate element quantities
      (p', e', q', v', ss', vdov, arealg)
          = lagrangeElements param dt x' dx' v v0 q e p mZ

      -- Calculate timestep constraints
      (dtc, dth)
          = calcTimeConstraints param ss' vdov arealg
  in
  (x', dx', e', p', q', v', ss', dtc, dth)


-- Advance Node Quantities
-- -----------------------

-- | Advance the nodal mesh variables, primarily the velocity and position. The
-- main steps are:
--
--   1. Calculate the nodal forces: 'calcForceForNodes'
--   2. Calculate nodal accelerations: 'calcAccelerationForNodes'
--   3. Apply acceleration boundary conditions ('applyAccelerationBoundaryConditionsForNodes, but called from (2))
--   4. Integrate nodal accelerations to obtain updated velocities: 'calcVelocityForNodes'
--   5. Integrate nodal velocities to obtain updated positions: 'calcPositionForNodes'
--
lagrangeNodal
    :: Parameters
    -> Exp Time
    -> Acc (Field Position)
    -> Acc (Field Velocity)
    -> Acc (Field Pressure)
    -> Acc (Field Viscosity)
    -> Acc (Field Volume)       -- relative volume
    -> Acc (Field Volume)       -- reference volume
    -> Acc (Field R)            -- speed of sound
    -> Acc (Field Mass)         -- element mass
    -> Acc (Field Mass)         -- nodal mass
    -> ( Acc (Field Position)
       , Acc (Field Velocity) )
lagrangeNodal param dt position velocity pressure viscosity volumeRel volumeRef soundSpeed elemMass nodalMass =
  let
      -- Time of boundary condition evaluation is beginning of step for force
      -- and acceleration boundary conditions
      force             = calcForceForNodes param position velocity pressure viscosity volumeRel volumeRef soundSpeed elemMass
      acceleration      = calcAccelerationForNodes force nodalMass
      velocity'         = calcVelocityForNodes param dt velocity acceleration
      position'         = calcPositionForNodes dt position velocity'
  in
  (position', velocity')


-- | Calculate the three-dimensional force vector F at each mesh node based on
-- the values of mesh variables at time t_n.
--
-- A volume force contribution is calculated within each mesh element. This is
-- then distributed to the surrounding nodes.
--
calcForceForNodes
    :: Parameters
    -> Acc (Field Position)
    -> Acc (Field Velocity)
    -> Acc (Field Pressure)
    -> Acc (Field Viscosity)
    -> Acc (Field Volume)       -- volume
    -> Acc (Field Volume)       -- reference valume
    -> Acc (Field R)            -- sound speed
    -> Acc (Field Mass)
    -> Acc (Field Force)
calcForceForNodes param position velocity pressure viscosity volumeRel volumeRef soundSpeed elemMass
  = distributeToNode (+) 0
  $ calcVolumeForceForElems param position velocity pressure viscosity volumeRel volumeRef soundSpeed elemMass


-- | Calculate the volume force contribute for each hexahedral mesh element. The
-- main steps are:
--
--  1. Initialise stress terms for each element
--  2. Integrate the volumetric stress terms for each element
--  3. Calculate the hourglass control contribution for each element.
--
calcVolumeForceForElems
    :: Parameters
    -> Acc (Field Position)
    -> Acc (Field Velocity)
    -> Acc (Field Pressure)
    -> Acc (Field Viscosity)
    -> Acc (Field Volume)
    -> Acc (Field Volume)
    -> Acc (Field R)
    -> Acc (Field Mass)
    -> Acc (Field (Hexahedron Force))
calcVolumeForceForElems Parameters{..} position velocity pressure viscosity volumeRel volumeRef soundSpeed elemMass =
  let
      numNode           = indexHead (shape position)
      numElem           = numNode - 1
      sh                = index3 numElem numElem numElem

      -- sum contributions to total stress tensor
      sigma             = A.zipWith initStressTermsForElem pressure viscosity

      -- calculate nodal forces from element stresses
      (stress, _determ) = A.unzip
                        $ A.zipWith integrateStressForElem
                                    (generate sh (collectToElem position))
                                    sigma

      -- TODO: check for negative element volume
      -- A.any (<=* 0) determ --> error

      -- Calculate the hourglass control contribution for each element
      hourglass         = generate sh $ \ix ->
        let pos         = collectToElem position ix
            vel         = collectToElem velocity ix

            v           = volumeRel  ! ix
            volo        = volumeRef  ! ix
            ss          = soundSpeed ! ix
            mass        = elemMass   ! ix
        in
        calcHourglassControlForElem pos vel volo v ss mass hgcoef

      -- Add the nodal forces
      combine :: Exp (Hexahedron Force) -> Exp (Hexahedron Force) -> Exp (Hexahedron Force)
      combine x y       = lift ( x^._0 + y^._0
                               , x^._1 + y^._1
                               , x^._2 + y^._2
                               , x^._3 + y^._3
                               , x^._4 + y^._4
                               , x^._5 + y^._5
                               , x^._6 + y^._6
                               , x^._7 + y^._7 )
  in
  A.zipWith combine stress hourglass


-- | Initialize stress terms for each element. Our assumption of an inviscid
-- isotropic stress tensor implies that the three principal stress components
-- are equal, and the shear stresses are zero. Thus, we initialize the diagonal
-- terms of the stress tensor sigma to −(p + q) in each element.
--
initStressTermsForElem
    :: Exp Pressure
    -> Exp Viscosity
    -> Exp Sigma
initStressTermsForElem p q =
  let s = -p - q
  in  lift (V3 s s s)


-- | Integrate the volumetric stress contributions for each element.
--
-- In the reference LULESH code, the forces at each of the corners of the
-- hexahedron defining this element would be distributed to the nodal mesh. This
-- corresponds to a global scatter operation.
--
-- Instead, we just return all the values directly, and the individual
-- contributions to the nodes will be combined in a different step.
--
integrateStressForElem
    :: Exp (Hexahedron Position)
    -> Exp Sigma
    -> Exp (Hexahedron Force, Volume)
integrateStressForElem p sigma =
  let
      -- Volume calculation involves extra work for numerical consistency
      det    = calcElemShapeFunctionDerivatives p ^._1
      b      = calcElemNodeNormals p
      f      = sumElemStressesToNodeForces b sigma
  in
  lift (f, det)


-- Calculate the shape function derivative for the element. This is used to
-- compute the velocity gradient of the element.
--
calcElemShapeFunctionDerivatives
    :: Exp (Hexahedron Position)                -- node coordinates bounding this hexahedron
    -> Exp (Hexahedron Force, Volume)           -- (shape function derivatives, jacobian determinant (volume))
calcElemShapeFunctionDerivatives p =
  let
      -- compute diagonal differences
      d60       = p^._6 - p^._0
      d53       = p^._5 - p^._3
      d71       = p^._7 - p^._1
      d42       = p^._4 - p^._2

      -- compute jacobians
      fj_xi     = 0.125 * ( d60 + d53 - d71 - d42 )
      fj_eta    = 0.125 * ( d60 - d53 + d71 - d42 )
      fj_zeta   = 0.125 * ( d60 + d53 + d71 + d42 )

      -- calculate cofactors (= determinant??)
      cj_xi     = cross fj_eta  fj_zeta
      cj_eta    = cross fj_zeta fj_xi
      cj_zeta   = cross fj_xi   fj_eta

      -- calculate partials
      -- By symmetry, [6,7,4,5] = - [0,1,2,3]
      b0        = - cj_xi - cj_eta - cj_zeta
      b1        =   cj_xi - cj_eta - cj_zeta
      b2        =   cj_xi + cj_eta - cj_zeta
      b3        = - cj_xi + cj_eta - cj_zeta
      b4        = -b2
      b5        = -b3
      b6        = -b0
      b7        = -b1

      -- calculate jacobian determinant (volume)
      volume    = 0.8 * dot fj_eta cj_eta
  in
  lift ((b0, b1, b2, b3, b4, b5, b6, b7), volume)



-- | Calculate normal vectors at element nodes, as an interpolation of element
-- face normals.
--
--  1. The normal at each node of the element is initially zero
--
--  2. Enumerate all six faces of the element. For each face, calculate a normal
--     vector, scale the magnitude by one quarter, and sum the scaled vector
--     into each of the four nodes of the element corresponding to a face.
--
calcElemNodeNormals
    :: Exp (Hexahedron Position)
    -> Exp (Hexahedron Normal)
calcElemNodeNormals p =
  let
      -- Calculate a face normal
      --
      surfaceElemFaceNormal :: Exp (Quad Position) -> Exp Normal
      surfaceElemFaceNormal p =
        let
            bisectx   = 0.5 * (p^._3 + p^._2 - p^._1 - p^._0)
            bisecty   = 0.5 * (p^._2 + p^._1 - p^._3 - p^._0)
        in
        0.25 * cross bisectx bisecty

      -- The normals at each of the six faces of the hexahedron.
      --
      -- The direction that we trace out the coordinates forming a face is such
      -- that it points towards the inside the hexahedron (RH-rule)
      --
      n0     = surfaceElemFaceNormal (collectFace 0 p)  -- corners: 0, 1, 2, 3
      n1     = surfaceElemFaceNormal (collectFace 1 p)  -- corners: 0, 4, 5, 1
      n2     = surfaceElemFaceNormal (collectFace 2 p)  -- corners: 1, 5, 6, 2
      n3     = surfaceElemFaceNormal (collectFace 3 p)  -- corners: 2, 6, 7, 3
      n4     = surfaceElemFaceNormal (collectFace 4 p)  -- corners: 3, 7, 4, 0
      n5     = surfaceElemFaceNormal (collectFace 5 p)  -- corners: 4, 7, 6, 5

      -- The normal at each node is then the sum of the normals of the three
      -- faces that meet at that node.
  in
  lift ( n0 + n1 + n4
       , n0 + n1 + n2
       , n0 + n2 + n3
       , n0 + n3 + n4
       , n1 + n4 + n5
       , n1 + n2 + n5
       , n2 + n3 + n5
       , n3 + n4 + n5
       )


-- | Sum force contribution in element to local vector for each node around
-- element.
--
sumElemStressesToNodeForces
    :: Exp (Hexahedron Normal)
    -> Exp Sigma
    -> Exp (Hexahedron Force)
sumElemStressesToNodeForces pf sigma =
  over each (\x -> -sigma * x) pf       -- interesting shorthand to map over a tuple


-- | Calculate the volume derivatives for an element. Starting with a formula
-- for the volume of a hexahedron, take the derivative of that volume formula
-- with respect to the coordinates at one of the nodes. By symmetry, the formula
-- for one node can be applied to each of the other seven nodes
--
calcElemVolumeDerivative
    :: Exp (Hexahedron Position)
    -> Exp (Hexahedron (V3 R))
calcElemVolumeDerivative p =
  let
      volumeDerivative :: Exp (V3 R, V3 R, V3 R, V3 R, V3 R, V3 R) -> Exp (V3 R)
      volumeDerivative p =
        let p01 = p^._0 + p^._1
            p12 = p^._1 + p^._2
            p04 = p^._0 + p^._4
            p34 = p^._3 + p^._4
            p25 = p^._2 + p^._5
            p35 = p^._3 + p^._5
        in
        (1/12) * cross p12 p01 + cross p04 p34 + cross p35 p25
  in
  lift ( volumeDerivative (lift (p^._1, p^._2, p^._3, p^._4, p^._5, p^._7))
       , volumeDerivative (lift (p^._0, p^._1, p^._2, p^._7, p^._4, p^._6))
       , volumeDerivative (lift (p^._3, p^._0, p^._1, p^._6, p^._7, p^._5))
       , volumeDerivative (lift (p^._2, p^._3, p^._0, p^._5, p^._6, p^._4))
       , volumeDerivative (lift (p^._7, p^._6, p^._5, p^._0, p^._3, p^._1))
       , volumeDerivative (lift (p^._4, p^._7, p^._6, p^._1, p^._0, p^._2))
       , volumeDerivative (lift (p^._5, p^._4, p^._7, p^._2, p^._1, p^._3))
       , volumeDerivative (lift (p^._6, p^._5, p^._4, p^._3, p^._2, p^._0))
       )


-- Calculate the hourglass control contribution for each element.
--
-- For each element:
--
--  1. Gather the node coordinates for that element.
--  2. Calculate the element volume derivative.
--  3. Perform a diagnosis check for any element volumes <= zero
--  4. Compute the Flanagan-Belytschko hourglass control force for each element.
--     This is described in the paper:
--
--     [1] "A uniform strain hexahedron and quadrilateral with orthogonal
--         hourglass control", Flanagan, D. P. and Belytschko, T. International
--         Journal for Numerical Methods in Engineering, (17) 5, May 1981.
--
calcHourglassControlForElem
    :: Exp (Hexahedron Position)
    -> Exp (Hexahedron Velocity)
    -> Exp Volume                       -- relative volume
    -> Exp Volume                       -- reference volume
    -> Exp R                            -- speed of sound
    -> Exp Mass                         -- mass
    -> Exp R
    -> Exp (Hexahedron Force)
calcHourglassControlForElem pos vel volo v ss mass hourg =
  let dvol      = calcElemVolumeDerivative pos
      determ    = volo * v
  in
  if hourg >* 0
     then calcFBHourglassForceForElem pos vel determ dvol ss mass hourg
     else constant (0,0,0,0,0,0,0,0)


calcFBHourglassForceForElem
    :: Exp (Hexahedron Position)
    -> Exp (Hexahedron Velocity)
    -> Exp Volume
    -> Exp (Hexahedron (V3 R))          -- from calcElemVolumeDerivative
    -> Exp R                            -- speed of sound
    -> Exp Mass                         -- mass
    -> Exp R
    -> Exp (Hexahedron Force)
calcFBHourglassForceForElem pos vel determ dvol ss mass hourg =
  let
      -- Hourglass base vectors, from [1] table 1. This defines the hourglass
      -- patterns for a unit cube.
      --
      gamma :: Exp (Hexahedron (V4 R))
      gamma = constant
        ( V4 ( 1) ( 1) ( 1) (-1)
        , V4 ( 1) (-1) (-1) ( 1)
        , V4 (-1) (-1) ( 1) (-1)
        , V4 (-1) ( 1) (-1) ( 1)
        , V4 (-1) (-1) ( 1) ( 1)
        , V4 (-1) ( 1) (-1) (-1)
        , V4 ( 1) ( 1) ( 1) ( 1)
        , V4 ( 1) (-1) (-1) (-1)
        )

      -- Compute hourglass modes
      --
      hourgam :: Exp (Hexahedron (V4 R))
      hourgam =
        let hg :: Exp (V4 R) -> Exp (Position) -> Exp (V3 R) -> Exp (V4 R)
            hg g p dv   = (1 - volinv * dot dv p) *^ g

            volinv      = 1 / determ
        in
        lift ( hg (gamma^._0) (pos^._0) (dvol^._0)
             , hg (gamma^._1) (pos^._1) (dvol^._1)
             , hg (gamma^._2) (pos^._2) (dvol^._2)
             , hg (gamma^._3) (pos^._3) (dvol^._3)
             , hg (gamma^._4) (pos^._4) (dvol^._4)
             , hg (gamma^._5) (pos^._5) (dvol^._5)
             , hg (gamma^._6) (pos^._6) (dvol^._6)
             , hg (gamma^._7) (pos^._7) (dvol^._7)
             )

      -- Compute forces
      cbrt x      = x ** (1/3)          -- cube root
      coefficient = - hourg * 0.01 * ss * mass / cbrt determ
  in
  calcElemFBHourglassForce coefficient vel hourgam


calcElemFBHourglassForce
    :: Exp R
    -> Exp (Hexahedron Velocity)
    -> Exp (Hexahedron (V4 R))
    -> Exp (Hexahedron Force)
calcElemFBHourglassForce coefficient vel hourgam =
  let
      -- TLM: this looks like a small matrix multiplication?

      h00, h01, h02, h03 :: Exp (V3 R)
      h00 = P.sum $ P.zipWith (*^) (hourgam ^.. (each._x)) (vel ^.. each)
      h01 = P.sum $ P.zipWith (*^) (hourgam ^.. (each._y)) (vel ^.. each)
      h02 = P.sum $ P.zipWith (*^) (hourgam ^.. (each._z)) (vel ^.. each)
      h03 = P.sum $ P.zipWith (*^) (hourgam ^.. (each._w)) (vel ^.. each)

      hh :: Exp (V4 (V3 R))
      hh  = lift (V4 h00 h01 h02 h03)

      hg :: Exp (V4 R) -> Exp Force
      hg h = coefficient *^ (P.sum $ P.zipWith (*^) (h^..each) (hh^..each))
  in
  over each hg hourgam


-- | Calculate the three-dimensional acceleration vector at each mesh node, and
-- apply the symmetry boundary conditions.
--
calcAccelerationForNodes
    :: Acc (Field Force)
    -> Acc (Field Mass)
    -> Acc (Field Acceleration)
calcAccelerationForNodes force mass
  = applyAccelerationBoundaryConditionsForNodes
  $ A.zipWith (^/) force mass


-- | Applies symmetry boundary conditions at nodes on the boundaries of the
-- mesh. This sets the normal component of the acceleration vector at the
-- boundary to zero. This implies that the normal component of the velocity
-- vector will remain constant in time.
--
-- Recall that the benchmark Sedov problem is spherically-symmetric and that we
-- simulate it in a cubic domain containing a single octant of the sphere. To
-- maintain spherical symmetry of the domain, we apply symmetry boundary
-- conditions along the faces of the cubic domain that contact the planes
-- separating the octants of the sphere. This forces the normal component of the
-- velocity vector to be zero along these boundary faces for all time, since
-- they were initialised to zero.
--
applyAccelerationBoundaryConditionsForNodes
    :: Acc (Field Acceleration)
    -> Acc (Field Acceleration)
applyAccelerationBoundaryConditionsForNodes acc =
  generate (shape acc) $ \ix ->
    let
        Z :. z :. y :. x        = unlift ix
        V3 xd yd zd             = unlift $ acc ! ix
    in
    lift $ V3 (x ==* 0 ? (0, xd))
              (y ==* 0 ? (0, yd))
              (z ==* 0 ? (0, zd))


-- | Integrate the acceleration at each node to advance the velocity at the
-- node.
--
-- Note that the routine applies a cutoff to each velocity vector value.
-- Specifically, if a value is below some prescribed threshold the term is set
-- to zero. The reason for this cutoff is to prevent spurious mesh motion which
-- may arise due to floating point roundoff error when the velocity is near
-- zero.
--
calcVelocityForNodes
    :: Parameters
    -> Exp Time
    -> Acc (Field Velocity)
    -> Acc (Field Acceleration)
    -> Acc (Field Velocity)
calcVelocityForNodes Parameters{..} dt u ud
  = A.map (over each (\x -> abs x <* u_cut ? (0,x)))
  $ integrate dt u ud

-- | Integrate the velocity at each node to advance the position of the node
--
calcPositionForNodes
    :: Exp Time
    -> Acc (Field Position)
    -> Acc (Field Velocity)
    -> Acc (Field Position)
calcPositionForNodes = integrate


-- | Euler integration
--
integrate
    :: Exp Time
    -> Acc (Field (V3 R))
    -> Acc (Field (V3 R))
    -> Acc (Field (V3 R))
integrate dt
  = A.zipWith (\x xd -> x + xd ^* dt)


-- Advance Element Quantities
-- --------------------------

-- | Advance element quantities, primarily pressure, internal energy, and
-- relative volume. The artificial viscosity in each element is also calculated
-- here. The main steps are:
--
--   1. Calculate element quantities based on nodal kinematic quantities
--   2. Calculate element artificial viscosity terms
--   3. Apply material properties in each element needed to calculate updated
--      pressure and internal energy.
--   4. Compute updated element volume
--
lagrangeElements
    :: Parameters
    -> Exp Time
    -> Acc (Field Position)
    -> Acc (Field Velocity)
    -> Acc (Field Volume)
    -> Acc (Field Volume)
    -> Acc (Field Viscosity)
    -> Acc (Field Energy)
    -> Acc (Field Pressure)
    -> Acc (Field Mass)
    -> ( Acc (Field Pressure)
       , Acc (Field Energy)
       , Acc (Field Viscosity)
       , Acc (Field Volume)
       , Acc (Field R)
       , Acc (Field R)
       , Acc (Field R) )
lagrangeElements params dt position velocity relativeVolume referenceVolume viscosity energy pressure elemMass =
  let
      (newVol, deltaVol, vdov, arealg)
          = calcLagrangeElements dt position velocity relativeVolume referenceVolume

      (ql, qq)
          = calcQForElems params position velocity newVol referenceVolume elemMass vdov

      (p, e, q, ss)
          = A.unzip4
          $ A.zipWith7 (calcEOSForElem params) newVol deltaVol energy pressure viscosity ql qq

      vol = A.map (updateVolumeForElem params) newVol
  in
  (p, e, q, vol, ss, vdov, arealg)


-- | Calculate various element quantities that are based on the new kinematic
-- node quantities position and velocity.
--
-- TODO: Check for negative element volume
--
calcLagrangeElements
    :: Exp Time
    -> Acc (Field Position)     -- nodal position
    -> Acc (Field Velocity)     -- nodal velocity
    -> Acc (Field Volume)       -- relative volume
    -> Acc (Field Volume)       -- reference volume
    -> ( Acc (Field Volume)
       , Acc (Field Volume)
       , Acc (Field R)
       , Acc (Field R) )
calcLagrangeElements dt position velocity relativeVolume referenceVolume =
  let
      numNode           = indexHead (shape position)
      numElem           = numNode - 1
      sh                = index3 numElem numElem numElem

      -- calculate new element quantities based on updated position and velocity
      (volRel, deltaVol, vdov, arealg)
        = A.unzip4
        $ A.generate sh $ \ix ->
            let
                p       = collectToElem position ix
                v       = collectToElem velocity ix
                vol     = relativeVolume  ! ix
                vol0    = referenceVolume ! ix
            in
            calcKinematicsForElem dt p v vol vol0
  in
  (volRel, deltaVol, vdov, arealg)


-- | Calculate terms in the total strain rate tensor epsilon_tot that are used
-- to compute the terms in the deviatoric strain rate tensor epsilon.
--
calcKinematicsForElem
    :: Exp Time
    -> Exp (Hexahedron Position)
    -> Exp (Hexahedron Velocity)
    -> Exp Volume
    -> Exp Volume
    -> Exp (Volume, Volume, R, R)
calcKinematicsForElem dt p v volRelOld vol0 =
  let
      -- (relative) volume calculations
      vol       = calcElemVolume p
      volRel    = vol / vol0
      deltaVol  = volRel - volRelOld

      -- characteristic length
      arealg    = calcElemCharacteristicLength p vol

      -- modify nodal positions to be halfway between time(n) and time(n+1)
      mid :: Exp (V3 R) -> Exp (V3 R) -> Exp (V3 R)
      mid x xd  = x - 0.5 * dt *^ xd

      p'        = lift ( mid (p^._0) (v^._0)
                       , mid (p^._1) (v^._1)
                       , mid (p^._2) (v^._2)
                       , mid (p^._3) (v^._3)
                       , mid (p^._4) (v^._4)
                       , mid (p^._5) (v^._5)
                       , mid (p^._6) (v^._6)
                       , mid (p^._7) (v^._7)
                       )

      -- Use midpoint nodal positions to calculate velocity gradient and
      -- strain rate tensor
      (b, det)  = unlift $ calcElemShapeFunctionDerivatives p'
      d         = calcElemVelocityGradient v b det

      -- calculate the deviatoric strain rate tensor
      vdov      = P.sum (unlift d :: V3 (Exp R))        -- no foldable instance for (Exp V3) ):
      _strain   = d ^- (vdov / 3.0)
  in
  lift (volRel, deltaVol, vdov, arealg)


-- | Calculate the volume of an element given the nodal coordinates
--
calcElemVolume
    :: Exp (Hexahedron Position)
    -> Exp Volume
calcElemVolume p =
  let
      -- compute diagonal differences
      d61       = p^._6 - p^._1
      d70       = p^._7 - p^._0
      d63       = p^._6 - p^._3
      d20       = p^._2 - p^._0
      d50       = p^._5 - p^._0
      d64       = p^._6 - p^._4
      d31       = p^._3 - p^._1
      d72       = p^._7 - p^._2
      d43       = p^._4 - p^._3
      d57       = p^._5 - p^._7
      d14       = p^._1 - p^._4
      d25       = p^._2 - p^._5
  in
  (1/12) * ( triple (d31 + d72) d63 d20
           + triple (d43 + d57) d64 d70
           + triple (d14 + d25) d61 d50
           )


-- | Calculate the characteristic length of the element. This is the volume of
-- the element divided by the area of its largest face.
--
calcElemCharacteristicLength
    :: Exp (Hexahedron Position)
    -> Exp Volume
    -> Exp R
calcElemCharacteristicLength p v =
  let
      faceArea :: Exp (Quad Position) -> Exp R
      faceArea face =
        let
            d20 = face^._2 - face^._0
            d31 = face^._3 - face^._1
            f   = d20 - d31
            g   = d20 + d31
            h   = dot f g
        in
        dot f f * dot g g - h * h

      area = P.maximum
           $ P.map faceArea
           $ P.map (flip collectFace p) [0..5]
  in
  4.0 * v / sqrt area


-- | Calculate the element velocity gradient which defines the terms of
-- epsilon_tot. The diagonal entries of epsilon_tot are then used to initialise
-- the diagonal entries of the strain rate tensor epsilon.
--
calcElemVelocityGradient
    :: Exp (Hexahedron Velocity)
    -> Exp (Hexahedron Force)
    -> Exp Volume
    -> Exp (V3 R)
calcElemVelocityGradient v b det =
  let
      -- TLM: unfortunately the (Accelerate) simplifier does not spot that the
      --      off-diagonal elements of the matrix are unused. Thus, we will need
      --      to rely on the code generator / backend compiler to remove those
      --      expressions as dead code.
      --
      inv_det = 1 / det
      mm      = inv_det *!! (transpose pf !*! vd)

      vd :: Exp (M43 R)
      vd = lift $ V4 (v^._0 - v^._6)
                     (v^._1 - v^._7)
                     (v^._2 - v^._4)
                     (v^._3 - v^._5)

      pf :: Exp (M43 R)
      pf = lift $ V4 (b^._0)
                     (b^._1)
                     (b^._2)
                     (b^._3)

      -- d3 = 0.5 * ( mm^._z._y + mm^._y._z )   -- 0.5 * ( dzddy + dyddz )
      -- d4 = 0.5 * ( mm^._x._z + mm^._z._x )   -- 0.5 * ( dxddz + dzddx )
      -- d5 = 0.5 * ( mm^._x._y + mm^._y._x )   -- 0.5 * ( dxddy + dyddx )
  in
  diagonal mm


-- | Calculate the artificial viscosity term for each element. The mathematical
-- aspects of the algorithm are described in [2]:
--
--   [2] Christensen, Randy B. "Godunov methods on a staggered mesh: An improved
--       artificial viscosity". Lawrence Livermore National Laboratory Report,
--       UCRL-JC-105-269, 1991. https://e-reports-ext.llnl.gov/pdf/219547.pdf
--
-- TODO: Don't allow excessive artificial viscosity. If any q > qstop: exit
--
calcQForElems
    :: Parameters
    -> Acc (Field Position)
    -> Acc (Field Velocity)
    -> Acc (Field Volume)
    -> Acc (Field Volume)
    -> Acc (Field Mass)
    -> Acc (Field R)            -- vdot / v
    -> ( Acc (Field Viscosity)
       , Acc (Field Viscosity) )
calcQForElems params position velocity relativeVolume referenceVolume mass vdov =
  let
      numNode           = indexHead (shape position)
      numElem           = numNode - 1
      sh                = index3 numElem numElem numElem

      -- calculate velocity gradients
      (grad_p, grad_v)
        = A.unzip
        $ A.generate sh $ \ix ->
            let
                p       = collectToElem position ix
                v       = collectToElem velocity ix
                volRel  = relativeVolume  ! ix
                volRef  = referenceVolume ! ix
            in
            calcMonotonicQGradientsForElem p v volRel volRef

      -- Transfer velocity gradients in the first order elements
      (ql, qq)
        = calcMonotonicQForElems params grad_p grad_v relativeVolume referenceVolume mass vdov

      -- TODO: don't allow excessive artificial viscosity
      -- A.maximum q >* qstop --> error
  in
  (ql, qq)


-- | Calculate discrete spatial gradients of nodal coordinates and velocity
-- gradients with respect to a reference coordinate system. The following maps
-- an element to the unit cube:
--
--   (x,y,z) ↦ (xi, eta, zeta)
--
-- Mapping the element to the unit cube simplifies the process of defining a
-- single value for the viscosity in the element from the gradient information.
--
calcMonotonicQGradientsForElem
    :: Exp (Hexahedron Position)
    -> Exp (Hexahedron Velocity)
    -> Exp Volume
    -> Exp Volume
    -> Exp (Gradient Position, Gradient Velocity)
calcMonotonicQGradientsForElem p v volRel vol0 =
  let
      vol               = volRel * vol0
      ivol              = 1 / vol

      p_eta, p_xi, p_zeta :: Exp Position
      p_eta             = 0.25 *^ (sumOf each (collectFace 3 p) - sumOf each (collectFace 1 p))
      p_xi              = 0.25 *^ (sumOf each (collectFace 2 p) - sumOf each (collectFace 4 p))
      p_zeta            = 0.25 *^ (sumOf each (collectFace 5 p) - sumOf each (collectFace 0 p))

      v_eta, v_xi, v_zeta :: Exp Velocity
      v_eta             = 0.25 *^ (sumOf each (collectFace 3 v) - sumOf each (collectFace 1 v))
      v_xi              = 0.25 *^ (sumOf each (collectFace 2 v) - sumOf each (collectFace 4 v))
      v_zeta            = 0.25 *^ (sumOf each (collectFace 5 v) - sumOf each (collectFace 0 v))

      a                 = cross p_xi   p_eta
      b                 = cross p_eta  p_zeta
      c                 = cross p_zeta p_xi

      grad_x            = V3 (vol / norm b)
                             (vol / norm c)
                             (vol / norm a)

      grad_v            = V3 (ivol * dot b v_xi)
                             (ivol * dot c v_eta)
                             (ivol * dot a v_zeta)
  in
  lift (grad_x, grad_v)


-- | Use the spatial gradient information to compute linear and quadratic terms
-- for viscosity. The actual element values of viscosity (q) are calculated
-- during application of material properties in each element; see
-- 'applyMaterialPropertiesForElem'.
--
calcMonotonicQForElems
    :: Parameters
    -> Acc (Field (Gradient Position))
    -> Acc (Field (Gradient Velocity))
    -> Acc (Field Mass)
    -> Acc (Field Volume)
    -> Acc (Field Volume)
    -> Acc (Field R)                    -- vdot / v
    -> ( Acc (Field Viscosity)          -- ql
       , Acc (Field Viscosity) )        -- qq
calcMonotonicQForElems Parameters{..} grad_x grad_v volNew volRef elemMass vdov =
  let
      sh                = shape grad_x
      numElem           = indexHead sh

      -- Need to compute a stencil on the neighbouring elements of the velocity
      -- gradients. However, we have different boundary conditions depending on
      -- whether we are at an internal/symmetric (= clamp) or external/free (=
      -- set to zero) face. This procedure encodes that decision.
      --
      get :: Exp Int -> Exp Int -> Exp Int -> Exp (Gradient Velocity)
      get z y x =
        if x >=* numElem ||* y >=* numElem ||* z >=* numElem
           then zero                                            -- external face
           else grad_v ! index3 (max 0 z) (max 0 y) (max 0 x)   -- internal region

      -- Calculate one component of the phi term
      --
      calcPhi :: Exp R -> Exp R -> Exp R
      calcPhi m p =
        let
            phi = 0.5 * (m + p)
            m'  = m * monoq_max_slope
            p'  = p * monoq_max_slope
        in
        m' `min` phi `min` p' `max` 0 `min` monoq_limiter

      -- Calculate linear and quadratic terms for viscosity
      --
      viscosity = generate sh $ \ix@(unlift -> Z:.z:.y:.x) ->
        let
            phi = lift $
              V3 (calcPhi (get  z    y   (x-1) ^._x) (get  z    y   (x+1) ^._x))
                 (calcPhi (get  z   (y-1) x    ^._y) (get  z   (y+1) x    ^._y))
                 (calcPhi (get (z-1) y    x    ^._z) (get (z+1) y    x    ^._z))

            -- remove length scale
            dx          = grad_x ! ix
            dv          = grad_v ! ix
            dvx         = lift1 (fmap (max 0) :: V3 (Exp R) -> V3 (Exp R)) (dx * dv)

            rho         = elemMass!ix / (volRef!ix * volNew!ix)
            qlin        = -qlc_monoq * rho * dot dvx       (1 - phi)
            qquad       = -qqc_monoq * rho * dot (dvx*dvx) (1 - phi*phi)
        in
        if vdov ! ix >* 0
           then constant (0,0)
           else lift (qlin, qquad)
  in
  A.unzip viscosity


-- | Evaluate the Equation of State of the system to calculate the updated
-- pressure and internal energy of an element.
--
-- The reference implementation had a function 'applyMaterialPropertiesForElem',
-- which has been merged into this.
--
calcEOSForElem
    :: Parameters
    -> Exp Volume
    -> Exp Volume
    -> Exp Energy
    -> Exp Pressure
    -> Exp Viscosity
    -> Exp Viscosity            -- linear term
    -> Exp Viscosity            -- quadratic term
    -> Exp (Pressure, Energy, Viscosity, R)
calcEOSForElem param@Parameters{..} vol delta_vol e p q ql qq =
  let
      clamp     = (\x -> if eosvmin /=* 0 then max eosvmin x else x)
                . (\x -> if eosvmax /=* 0 then min eosvmax x else x)

      vol'      = clamp vol

      work      = 0
      comp      = 1 / vol' - 1
      comp'     = 1 / (vol' - delta_vol * 0.5) - 1

      (e', p', q', bvc, pbvc)   = calcEnergyForElem param e p q ql qq comp comp' vol' delta_vol work
      ss                        = calcSoundSpeedForElem param vol' e' p' bvc pbvc
  in
  lift (p', e', q', ss)


-- | Calculate pressure and energy for an element
--
calcEnergyForElem
    :: Parameters
    -> Exp Energy
    -> Exp Pressure
    -> Exp Viscosity
    -> Exp Viscosity            -- linear term
    -> Exp Viscosity            -- quadratic term
    -> Exp R                    -- compression
    -> Exp R                    -- half-step compression
    -> Exp Volume
    -> Exp Volume
    -> Exp R                    -- work
    -> (Exp Energy, Exp Pressure, Exp Viscosity, Exp R, Exp R)
calcEnergyForElem params@Parameters{..} e0 p0 q0 ql qq comp comp_half vol vol_delta work =
  let
      e1                = e_min `max` (e0 - 0.5 * vol_delta * (p0 + q0) + 0.5 * work)
      (p1, bvc1, pbvc1) = calcPressureForElem params e1 vol comp_half
      ssc1              = calcSoundSpeedForElem params (1/(1+comp_half)) e1 p1 bvc1 pbvc1
      q1                = vol_delta >* 0 ? (0, ssc1 * ql + qq )

      e2                = let e = e1
                                + 0.5 * vol_delta * (3.0 * (p0 + q0) - 4.0 * (p1 + q1))
                                + 0.5 * work
                          in
                          abs e <* e_cut ? (0, max e_min e )
      (p2, bvc2, pbvc2) = calcPressureForElem params e2 vol comp
      ssc2              = calcSoundSpeedForElem params vol e2 p2 bvc2 pbvc2
      q2                = vol_delta >* 0 ? (0, ssc2 * ql + qq)

      e3                = let e = e2 - 1/6 * vol_delta * ( 7.0 * (p0 + q0)
                                                         - 8.0 * (p1 + q1)
                                                         +       (p2 + q2) )
                          in
                          abs e <* e_cut ? (0, max e_min e)
      (p3, bvc3, pbvc3) = calcPressureForElem params e3 vol comp
      ssc3              = calcSoundSpeedForElem params vol e3 p3 bvc3 pbvc3
      q3                = let q = ssc3 * ql + qq
                          in abs q >* q_cut ? (0, q)
  in
  (e3, p3, q3, bvc3, pbvc3)


-- | Calculate the "gamma law" model of a gas:
--
--    P = (gamma - 1) (rho / rho0) e
--
--
calcPressureForElem
    :: Parameters
    -> Exp Energy
    -> Exp Volume
    -> Exp R
    -> (Exp Pressure, Exp R, Exp R)
calcPressureForElem Parameters{..} e vol comp =
  let
      c1s       = 2/3                   -- defined to be (gamma - 1)
      bvc       = c1s * (comp + 1)
      pbvc      = c1s
      p_new     = bvc * e
      p_new'    = if abs p_new <* p_cut ||* vol >=* eosvmax
                     then 0
                     else p_new
  in
  ( max p_min p_new', bvc, pbvc )


-- | Calculate the speed of sound in each element
--
--    c_sound = (p*e + V^2*p*(gamma-1)*(1/(V-1)+1)) / rho0
--
calcSoundSpeedForElem
    :: Parameters
    -> Exp Volume
    -> Exp Energy
    -> Exp Pressure
    -> Exp R
    -> Exp R
    -> Exp R
calcSoundSpeedForElem Parameters{..} v e p bvc pbvc =
  let
      ss = (pbvc * e + v * v * p * bvc ) / ref_dens
  in
  if ss <=* 1.111111e-36
     then 0.333333e-18
     else sqrt ss


-- | Update the relative volume, using a tolerance to prevent spurious
-- deviations from the initial values (which may arise due to floating point
-- roundoff error).
--
updateVolumeForElem
    :: Parameters
    -> Exp Volume
    -> Exp Volume
updateVolumeForElem Parameters{..} vol =
  if abs (vol - 1) <* v_cut
     then 1
     else vol


-- Time Constraints
-- ================

-- | After all the solution variables are moved to the next time step, the
-- constrains for next time increment are calculated. Each constraint is
-- computed in each element, and the final constraint is the minimum over all
-- element values.
--
calcTimeConstraints
    :: Parameters
    -> Acc (Field R)
    -> Acc (Field R)
    -> Acc (Field R)
    -> ( Acc (Scalar Time)
       , Acc (Scalar Time) )
calcTimeConstraints param ss vdov arealg =
  let
      dt_courant        = A.minimum $ A.zipWith3 (calcCourantConstraintForElem param) ss vdov arealg
      dt_hydro          = A.minimum $ A.map      (calcHydroConstraintForElem   param) vdov
  in
  (dt_courant, dt_hydro)


-- | The Courant-Friedrichs-Lewy (CFL) constraint is calculated only in elements
-- whose volumes are changing (vdov /= 0). This constraint is essentially the
-- ratio of the characteristic length of the element to the speed of sound in
-- that element. However, when the element is under compression (vdov < 0),
-- additional terms are added to the denominator to reduce the timestep further.
--
calcCourantConstraintForElem
    :: Parameters
    -> Exp R            -- sound speed
    -> Exp R            -- vdot / v
    -> Exp R            -- characteristic length
    -> Exp Time
calcCourantConstraintForElem Parameters{..} ss vdov arealg =
  if vdov ==* 0
     then 1.0e20
     else let
              qqc'      = 64 * qqc * qqc
              dtf       = ss * ss
                        + if vdov >* 0 then 0
                                       else qqc' * arealg * arealg * vdov * vdov
          in
          arealg / sqrt dtf


-- | Calculate the hydro time constraint in elements whose volumes are changing
-- (vdov /= 0). When the element is undergoing volume change, the timestep for
-- that element is some maximum allowable element volume change (prescribed)
-- divided by vdov in the element
--
calcHydroConstraintForElem
    :: Parameters
    -> Exp R            -- vdot / v
    -> Exp Time
calcHydroConstraintForElem Parameters{..} vdov =
  if vdov ==* 0
     then 1.0e20
     else dvovmax / (abs vdov + 1.0e-20)

