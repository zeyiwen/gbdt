/*
 * DeviceSplitterKernel.h
 *
 *  Created on: 10 May 2016
 *      Author: Zeyi Wen
 *		@brief: 
 */

#ifndef DEVICESPLITTERKERNEL_H_
#define DEVICESPLITTERKERNEL_H_

#include "../../Host/UpdateOps/NodeStat.h"
#include "../../Host/UpdateOps/SplitPoint.h"
#include "../../DeviceHost/BaseClasses/BaseSplitter.h"
#include "../../DeviceHost/DefineConst.h"

__global__ void FindFeaSplitValue2(int *pnNumofKeyValues, long long *pnFeaStartPos, const int *pInsId, const float_point *pFeaValue, const int *pInsIdToNodeId,
								  nodeStat *pTempRChildStatPerThread, const float_point *pGD, const float_point *pHess, float_point *pLastValuePerThread,
								  nodeStat *pSNodeStatPerThread, SplitPoint *pBestSplitPointPerThread,
								  nodeStat *pRChildStatPerThread, nodeStat *pLChildStatPerThread,
								  const int *pSNIdToBuffId, int maxNumofSplittable, const int *pBuffId, int numofSNode,
								  float_point lambda, int numofFea);
__global__ void PickBestFea(nodeStat *pTempRChildStatPerThread, float_point *pLastValuePerThread, nodeStat *pSNodeStatePerThread,
							SplitPoint *pBestSplitPointPerThread, nodeStat *pRChildStatPerThread, nodeStat *pLChildStatPerThread,
							int numofSNode, int numofFea, int maxNumofSplittable);

__global__ void FindFeaSplitValue(int nNumofKeyValues, const int *idStartAddress, const float_point *pValueStartAddress, const int *pInsIdToNodeId,
								  nodeStat *pTempRChildStat, const float_point *pGD, const float_point *pHess, float_point *pLastValue,
								  nodeStat *pSNodeState, SplitPoint *pBestSplitPoin, nodeStat *pRChildStat, nodeStat *pLChildStat,
								  const int *pSNIdToBuffId, int maxNumofSplittable, int featureId, const int *pBuffId, int numofSNode, float_point lambda);

__device__ double CalGain(const nodeStat &parent, const nodeStat &r_child, float_point &l_child_GD,
									 float_point &l_child_Hess, float_point &lambda);

__device__ bool UpdateSplitPoint(SplitPoint &curBest, double fGain, double fSplitValue, int nFeatureId);

__device__ void UpdateLRStat(nodeStat &RChildStat, nodeStat &LChildStat, nodeStat &TempRChildStat,
										float_point &grad, float_point &hess);
__device__ bool NeedUpdate(float_point &RChildHess, float_point &LChildHess);
__device__ void UpdateSplitInfo(nodeStat &snStat, SplitPoint &bestSP, nodeStat &RChildStat, nodeStat &LChildStat,
										 nodeStat &TempRChildStat, float_point &tempGD, float_point &temHess,
										 float_point &lambda, float_point &sv, int &featureId);


#endif /* DEVICESPLITTERKERNEL_H_ */
