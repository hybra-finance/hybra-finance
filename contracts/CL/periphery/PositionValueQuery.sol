// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.6;
pragma abicoder v2;

import 'contracts/core/interfaces/ICLPool.sol';
import './interfaces/INonfungiblePositionManager.sol';
import './libraries/PositionValue.sol';
import './libraries/PoolAddress.sol';

contract PositionValueQuery {
    INonfungiblePositionManager public immutable positionManager;
    
    struct PositionInfo {
        uint256 tokenId;
        uint256 amount0Principal;
        uint256 amount1Principal;
        uint256 amount0Fee;
        uint256 amount1Fee;
    }
    
   
    
    constructor(address _positionManager) {
        positionManager = INonfungiblePositionManager(_positionManager);
    }
    
    function getPrincipal(uint256 tokenId, uint160 sqrtRatioX96) 
        external 
        view 
        returns (uint256 amount0, uint256 amount1) 
    {
        return PositionValue.principal(positionManager, tokenId, sqrtRatioX96);
    }
    
    function getFees(uint256 tokenId) 
        external 
        view 
        returns (uint256 amount0, uint256 amount1) 
    {
        return PositionValue.fees(positionManager, tokenId);
    }
    
    function getTotal(uint256 tokenId, uint160 sqrtRatioX96) 
        external 
        view 
        returns (uint256 amount0, uint256 amount1) 
    {
        return PositionValue.total(positionManager, tokenId, sqrtRatioX96);
    }
    
    function getPositionInfo(uint256 tokenId) 
        external 
        view 
        returns (PositionInfo memory info) 
    {
        (, , address token0, address token1, int24 tickSpacing, , , , , , , ) = positionManager.positions(tokenId);
        
        ICLPool pool = ICLPool(
            PoolAddress.computeAddress(
                positionManager.factory(),
                PoolAddress.PoolKey({token0: token0, token1: token1, tickSpacing: tickSpacing})
            )
        );
        
        (uint160 sqrtRatioX96, , , , , ) = pool.slot0();
        
        info.tokenId = tokenId;
        (info.amount0Principal, info.amount1Principal) = PositionValue.principal(positionManager, tokenId, sqrtRatioX96);
        (info.amount0Fee, info.amount1Fee) = PositionValue.fees(positionManager, tokenId);
    }
    

    
    function getBatchPositionInfo(uint256[] calldata tokenIds)
        external
        view
        returns (PositionInfo[] memory infos)
    {
        infos = new PositionInfo[](tokenIds.length);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            (, , address token0, address token1, int24 tickSpacing, , , , , , ,  ) = positionManager.positions(tokenId);
            
            ICLPool pool = ICLPool(
                PoolAddress.computeAddress(
                    positionManager.factory(),
                    PoolAddress.PoolKey({token0: token0, token1: token1, tickSpacing: tickSpacing})
                )
            );
            
            (uint160 sqrtRatioX96, , , , ,  ) = pool.slot0();
            
            infos[i].tokenId = tokenId;
            (infos[i].amount0Principal, infos[i].amount1Principal) = PositionValue.principal(
                positionManager, 
                tokenId, 
                sqrtRatioX96
            );
            (infos[i].amount0Fee, infos[i].amount1Fee) = PositionValue.fees(positionManager, tokenId);
           
        }
    }
    
    function getPrincipalWithCustomPrice(uint256 tokenId, uint160 customSqrtRatioX96)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return PositionValue.principal(positionManager, tokenId, customSqrtRatioX96);
    }
    
    function getTotalWithCustomPrice(uint256 tokenId, uint160 customSqrtRatioX96)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return PositionValue.total(positionManager, tokenId, customSqrtRatioX96);
    }
    
  
}