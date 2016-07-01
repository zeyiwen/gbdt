/*
 * DeviceSplitterSplitNode.cu
 *
 *  Created on: 12 May 2016
 *      Author: Zeyi Wen
 *		@brief: GPU version of splitAll function
 */

#include <iostream>
#include <algorithm>

#include "../../DeviceHost/MyAssert.h"
#include "../Memory/gbdtGPUMemManager.h"
#include "../Memory/SplitNodeMemManager.h"
#include "DeviceSplitter.h"
#include "../Preparator.h"
#include "../Hashing.h"
#include "DeviceSplitAllKernel.h"
#include "../KernelConf.h"

using std::cout;
using std::endl;
using std::pair;
using std::make_pair;
using std::sort;


/**
 * @brief: split all splittable nodes of the current level
 * @numofNode: for computing new children ids
 */
void DeviceSplitter::SplitAll(vector<TreeNode*> &splittableNode, const vector<SplitPoint> &vBest, RegTree &tree, int &m_nNumofNode,
		 	 	 	    const vector<nodeStat> &rchildStat, const vector<nodeStat> &lchildStat, bool bLastLevel)
{
	int preMaxNodeId = m_nNumofNode - 1;
	PROCESS_ERROR(preMaxNodeId >= 0);

	#ifdef _COMPARE_HOST
	int nNumofSplittableNode = splittableNode.size();
	PROCESS_ERROR(nNumofSplittableNode > 0);
	PROCESS_ERROR(splittableNode.size() == vBest.size());
	PROCESS_ERROR(vBest.size() == rchildStat.size());
	PROCESS_ERROR(vBest.size() == lchildStat.size());
	#endif

	GBDTGPUMemManager manager;
	SNGPUManager snManager;//splittable node memory manager

	//compute the base_weight of tree node, also determines if a node is a leaf.
	KernelConf conf;
	dim3 dimGridThreadForEachSN;
	conf.ComputeBlock(manager.m_curNumofSplitable, dimGridThreadForEachSN);
	int sharedMemSizeSN = 1;
	ComputeWeight<<<dimGridThreadForEachSN, sharedMemSizeSN>>>(snManager.m_pTreeNode, manager.m_pSplittableNode, manager.m_pSNIdToBuffId,
			  	  	  	  	  manager.m_pBestSplitPoint, manager.m_pSNodeStat, rt_eps, LEAFNODE,
			  	  	  	  	  m_lambda, manager.m_curNumofSplitable, bLastLevel);

	#ifdef _COMPARE_HOST
	//################ original cpu code, now for testing
	for(int n = 0; n < nNumofSplittableNode; n++)
	{
		int nid = splittableNode[n]->nodeId;
//		cout << "node " << nid << " needs to split..." << endl;
//		cout << mapNodeIdToBufferPos.size() << endl;
		map<int, int>::iterator itBufferPos = mapNodeIdToBufferPos.find(nid);
		assert(itBufferPos != mapNodeIdToBufferPos.end());
		int bufferPos = mapNodeIdToBufferPos[nid];
		PROCESS_ERROR(bufferPos < vBest.size());
		//mark the node as a leaf node if (1) the gain is negative or (2) the tree reaches maximum depth.
		tree.nodes[nid]->loss = vBest[bufferPos].m_fGain;
		tree.nodes[nid]->base_weight = ComputeWeightSparseData(bufferPos);
		if(vBest[bufferPos].m_fGain <= rt_eps || bLastLevel == true)
		{
			//weight of a leaf node
			tree.nodes[nid]->predValue = tree.nodes[nid]->base_weight;
			tree.nodes[nid]->rightChildId = LEAFNODE;
		}
	}

	//testing. Compare the results from GPU with those from CPU
//	cout << "numof tree nodes is " << tree.nodes.size() << endl;
	for(int t = 0; t < tree.nodes.size(); t++)
	{
		TreeNode tempNode;
		manager.MemcpyDeviceToHost(snManager.m_pTreeNode + t, &tempNode, sizeof(TreeNode) * 1);
		if(tempNode.loss != tree.nodes[t]->loss)
		{
			cout << "t=" << t << "; " << tempNode.loss << " v.s " << tree.nodes[t]->loss << endl;
		}
		PROCESS_ERROR(tempNode.loss == tree.nodes[t]->loss);
		PROCESS_ERROR(tempNode.base_weight == tree.nodes[t]->base_weight);
		PROCESS_ERROR(tempNode.predValue == tree.nodes[t]->predValue);
		PROCESS_ERROR(tempNode.rightChildId == tree.nodes[t]->rightChildId);
	}
	//#################### end
	#endif

	//copy the number of nodes in the tree to the GPU memory
	manager.Memset(snManager.m_pNumofNewNode, 0, sizeof(int));
	CreateNewNode<<<dimGridThreadForEachSN, sharedMemSizeSN>>>(
							snManager.m_pTreeNode, manager.m_pSplittableNode, snManager.m_pNewSplittableNode,
							manager.m_pSNIdToBuffId, manager.m_pBestSplitPoint,
							snManager.m_pParentId, snManager.m_pLeftChildId, snManager.m_pRightChildId,
							manager.m_pLChildStat, manager.m_pRChildStat, snManager.m_pNewNodeStat,
							snManager.m_pCurNumofNode, snManager.m_pNumofNewNode, rt_eps, manager.m_curNumofSplitable, bLastLevel);

	#ifdef _COMPARE_HOST
	//####################### cpu code, now for testing
	//for each splittable node, assign lchild and rchild ids
	map<int, pair<int, int> > mapPidCid;//(parent id, (lchildId, rchildId)).
	vector<TreeNode*> newSplittableNode;
	vector<nodeStat> newNodeStat;
	for(int n = 0; n < nNumofSplittableNode; n++)
	{
		int nid = splittableNode[n]->nodeId;
//		cout << "node " << nid << " needs to split..." << endl;
		int bufferPos = mapNodeIdToBufferPos[nid];
		map<int, int>::iterator itBufferPos = mapNodeIdToBufferPos.find(nid);
		assert(itBufferPos != mapNodeIdToBufferPos.end() && bufferPos == itBufferPos->second);
		PROCESS_ERROR(bufferPos < vBest.size());

		if(!(vBest[bufferPos].m_fGain <= rt_eps || bLastLevel == true))
		{
			int lchildId = m_nNumofNode;
			int rchildId = m_nNumofNode + 1;

			mapPidCid.insert(make_pair(nid, make_pair(lchildId, rchildId)));

			//push left and right child statistics into a vector
			PROCESS_ERROR(lchildStat[bufferPos].sum_hess > 0);
			PROCESS_ERROR(rchildStat[bufferPos].sum_hess > 0);
			newNodeStat.push_back(lchildStat[bufferPos]);
			newNodeStat.push_back(rchildStat[bufferPos]);

			//split into two nodes
			TreeNode *leftChild = new TreeNode[1];
			TreeNode *rightChild = new TreeNode[1];

			leftChild->nodeId = lchildId;
			leftChild->parentId = nid;
			leftChild->level = tree.nodes[nid]->level + 1;
			rightChild->nodeId = rchildId;
			rightChild->parentId = nid;
			rightChild->level = tree.nodes[nid]->level + 1;

			newSplittableNode.push_back(leftChild);
			newSplittableNode.push_back(rightChild);

			tree.nodes.push_back(leftChild);
			tree.nodes.push_back(rightChild);

			tree.nodes[nid]->leftChildId = leftChild->nodeId;
			tree.nodes[nid]->rightChildId = rightChild->nodeId;
			PROCESS_ERROR(vBest[bufferPos].m_nFeatureId >= 0);
			tree.nodes[nid]->featureId = vBest[bufferPos].m_nFeatureId;
			tree.nodes[nid]->fSplitValue = vBest[bufferPos].m_fSplitValue;


			m_nNumofNode += 2;
		}
	}

	//testing. Compare the new splittable nodes form GPU with those from CPU
	for(int n = 0; n < newSplittableNode.size(); n++)
	{
		TreeNode tempNode;
		manager.MemcpyDeviceToHost(snManager.m_pNewSplittableNode + n, &tempNode, sizeof(TreeNode) * 1);
		if(tempNode.nodeId != newSplittableNode[n]->nodeId || tempNode.level != newSplittableNode[n]->level)
		{
			cout << "n=" << n << "; nid " << tempNode.nodeId << " v.s " << newSplittableNode[n]->nodeId
				 << "; level " << tempNode.level << " v.s. " << newSplittableNode[n]->level
				 << "; # of splittable is " << newSplittableNode.size() << endl;
		}
		PROCESS_ERROR(tempNode.nodeId == newSplittableNode[n]->nodeId);
		PROCESS_ERROR(tempNode.parentId == newSplittableNode[n]->parentId);
		PROCESS_ERROR(tempNode.level == newSplittableNode[n]->level);
	}
	//######################### end
	#endif

	//find all used unique feature ids. We will use these features to organise instances into new nodes.
	manager.Memset(snManager.m_pFeaIdToBuffId, -1, sizeof(int) * snManager.m_maxNumofUsedFea);
	manager.Memset(snManager.m_pUniqueFeaIdVec, -1, sizeof(int) * snManager.m_maxNumofUsedFea);
	manager.Memset(snManager.m_pNumofUniqueFeaId, 0, sizeof(int));
	GetUniqueFid<<<dimGridThreadForEachSN, sharedMemSizeSN>>>(snManager.m_pTreeNode, manager.m_pSplittableNode, manager.m_curNumofSplitable,
							 snManager.m_pFeaIdToBuffId, snManager.m_pUniqueFeaIdVec, snManager.m_pNumofUniqueFeaId,
			 	 	 	 	 snManager.m_maxNumofUsedFea, LEAFNODE, manager.m_nSNLock);

	#ifdef _COMPARE_HOST
	//######################### CPU code for getting all the used feature indices; now for testing.
	vector<int> vFid;
	for(int n = 0; n < nNumofSplittableNode; n++)
	{
		int fid = splittableNode[n]->featureId;
		int nid = splittableNode[n]->nodeId;
		if(fid == -1 && tree.nodes[nid]->rightChildId == LEAFNODE)
		{//leaf node should satisfy two conditions at this step
			continue;
		}
		PROCESS_ERROR(fid >= 0);
		vFid.push_back(fid);
	}

	if(vFid.size() == 0)
		PROCESS_ERROR(nNumofSplittableNode == 1 || bLastLevel == true);
	PROCESS_ERROR(vFid.size() <= nNumofSplittableNode);

	//find unique used feature ids
	DataPreparator preparator;
	int *pFidHost = new int[vFid.size()];
	preparator.VecToArray(vFid, pFidHost);
	//push all the elements into a hash map
	int numofUniqueFid = 0;
	int *pUniqueFidHost = new int[vFid.size()];
	preparator.m_pUsedFIDMap = new int[snManager.m_maxNumofUsedFea];
	memset(preparator.m_pUsedFIDMap, -1, snManager.m_maxNumofUsedFea);
	for(int i = 0; i < vFid.size(); i++)//get unique id by host
	{
		bool bIsNew = false;
		int hashValue = Hashing::HostAssignHashValue(preparator.m_pUsedFIDMap, vFid[i], snManager.m_maxNumofUsedFea, bIsNew);
		if(bIsNew == true)
		{
			pUniqueFidHost[numofUniqueFid] = vFid[i];
			numofUniqueFid++;
		}
	}

	TreeNode *pNewSNode1 = new TreeNode[manager.m_maxNumofSplittable];
	manager.MemcpyDeviceToHost(manager.m_pSplittableNode, pNewSNode1, sizeof(TreeNode) * manager.m_maxNumofSplittable);
	/*for(int s = 0; s < nNumofSplittableNode; s++)
	{
		int snid = splittableNode[s]->nodeId;
		PROCESS_ERROR(snid == pNewSNode1[s].nodeId);
		int sfid = splittableNode[s]->featureId;
		PROCESS_ERROR(sfid == pNewSNode1[s].featureId);
	}*/

	//comparing unique ids
	int *pUniqueIdFromDevice = new int[snManager.m_maxNumofUsedFea];
	int numofUniqueFromDevice = 0;
	manager.MemcpyDeviceToHost(snManager.m_pUniqueFeaIdVec, pUniqueIdFromDevice, sizeof(int) * snManager.m_maxNumofUsedFea);
	manager.MemcpyDeviceToHost(snManager.m_pNumofUniqueFeaId, &numofUniqueFromDevice, sizeof(int));
	if(numofUniqueFromDevice != numofUniqueFid)
	{
		for(int s = 0; s < nNumofSplittableNode; s++)
		{
			cout << splittableNode[s]->featureId << "\t";
		}
		cout << endl;

		for(int s = 0; s < 19; s++)
		{
			cout << pNewSNode1[s].featureId << "\t";
		}
		cout << endl;

//		PrintVec(vFid);
		cout << numofUniqueFid << " v.s. " << numofUniqueFromDevice << endl;
		for(int i = 0; i < numofUniqueFid; i++)
		{
			cout << pUniqueFidHost[i] << '\t';
		}
		cout << endl;
		for(int i = 0; i < numofUniqueFromDevice; i++)
		{
			cout << pUniqueIdFromDevice[i] << '\t';
		}
		cout << endl;
	}
	cout.flush();
	if(numofUniqueFromDevice != numofUniqueFid)
	{
		cout << "oh shit" << endl;
		exit(0);
	}
	PROCESS_ERROR(numofUniqueFromDevice == numofUniqueFid);
	for(int i = 0; i < numofUniqueFid; i++)
	{
		PROCESS_ERROR(pUniqueIdFromDevice[i] == pUniqueFidHost[i]);
	}

	delete[] pUniqueIdFromDevice;
	delete[] pFidHost;
	delete[] preparator.m_pUsedFIDMap;

	sort(vFid.begin(), vFid.end());
	vFid.resize(std::unique(vFid.begin(), vFid.end()) - vFid.begin());
	PROCESS_ERROR(vFid.size() <= nNumofSplittableNode);
	PROCESS_ERROR(vFid.size() == numofUniqueFid);
//	PrintVec(vFid);

//	int testBufferPos = mapNodeIdToBufferPos[8];
//	cout << "test buffer pos=" << testBufferPos << "; preMaxNodeId=" << preMaxNodeId << endl;
	//############################ end
	#endif

	//for each used feature to move instances to new nodes
	int numofUniqueFea = -1;
	manager.MemcpyDeviceToHost(snManager.m_pNumofUniqueFeaId, &numofUniqueFea, sizeof(int));
	dim3 dimGridThreadForEachUsedFea;
	conf.ComputeBlock(numofUniqueFea, dimGridThreadForEachUsedFea);
	int sharedMemSizeUsedFea = 1;
	InsToNewNode<<<dimGridThreadForEachUsedFea, sharedMemSizeUsedFea>>>(snManager.m_pTreeNode, manager.m_pdDFeaValue, manager.m_pDInsId,
						   	 manager.m_pFeaStartPos, manager.m_pDNumofKeyValue,
						   	 manager.m_pInsIdToNodeId, manager.m_pSNIdToBuffId, manager.m_pBestSplitPoint,
						   	 snManager.m_pUniqueFeaIdVec, snManager.m_pNumofUniqueFeaId,
							 snManager.m_pParentId, snManager.m_pLeftChildId, snManager.m_pRightChildId,
							 preMaxNodeId, manager.m_numofFea, manager.m_numofIns, LEAFNODE);

	#ifdef _COMPARE_HOST
	//############################ CPU code for each used feature to make decision; now for testing
	for(int u = 0; u < numofUniqueFid; u++)
	{
		int ufid = pUniqueFidHost[u];
		PROCESS_ERROR(ufid < m_vvFeaInxPair.size() && ufid >= 0);

		//for each instance that has value on the feature
		vector<KeyValue> &featureKeyValues = m_vvFeaInxPair[ufid];
		int nNumofPair = featureKeyValues.size();
		for(int i = 0; i < nNumofPair; i++)
		{
			int insId = featureKeyValues[i].id;
			PROCESS_ERROR(insId < m_nodeIds.size());
			int nid = m_nodeIds[insId];

			if(nid < 0)//leaf node
				continue;

			PROCESS_ERROR(nid >= 0);
			int bufferPos = mapNodeIdToBufferPos[nid];
			map<int, int>::iterator itBufferPos = mapNodeIdToBufferPos.find(nid);
			assert(itBufferPos != mapNodeIdToBufferPos.end());
			int fid = vBest[bufferPos].m_nFeatureId;
			if(fid != ufid)//this feature is not the splitting feature for the instance.
				continue;

			map<int, pair<int, int> >::iterator it = mapPidCid.find(nid);

			if(it == mapPidCid.end())//node doesn't need to split (leaf node or new node)
			{
				if(tree.nodes[nid]->rightChildId != LEAFNODE)
				{
					PROCESS_ERROR(nid > preMaxNodeId);
					continue;
				}
				PROCESS_ERROR(tree.nodes[nid]->rightChildId == LEAFNODE);
				continue;
			}

			if(it != mapPidCid.end())
			{//internal node (needs to split)
				PROCESS_ERROR(it->second.second == it->second.first + 1);//right child id > than left child id

				double fPivot = vBest[bufferPos].m_fSplitValue;
				double fvalue = featureKeyValues[i].featureValue;
				if(fvalue >= fPivot)
				{
					m_nodeIds[insId] = it->second.second;//right child id
				}
				else
					m_nodeIds[insId] = it->second.first;//left child id
			}
		}
	}

	//testing. Compare ins id to node id
	int *insIdToNodeIdHost = new int[manager.m_numofIns];
	manager.MemcpyDeviceToHost(manager.m_pInsIdToNodeId, insIdToNodeIdHost, sizeof(int) * manager.m_numofIns);
	for(int i = 0; i < manager.m_numofIns; i++)
	{
		PROCESS_ERROR(insIdToNodeIdHost[i] == m_nodeIds[i]);
	}

	delete[] pUniqueFidHost;//for storing unique used feature ids
	//############################# end
	#endif

	//for those instances of unknown feature values.
	dim3 dimGridThreadForEachIns;
	conf.ComputeBlock(manager.m_numofIns, dimGridThreadForEachIns);
	int sharedMemSizeIns = 1;

	InsToNewNodeByDefault<<<dimGridThreadForEachIns, sharedMemSizeIns>>>(
									snManager.m_pTreeNode, manager.m_pInsIdToNodeId, manager.m_pSNIdToBuffId,
									snManager.m_pParentId, snManager.m_pLeftChildId,
			   	   	   	   	   	   	preMaxNodeId, manager.m_numofIns, LEAFNODE);

	#ifdef _COMPARE_HOST
	//########################### CPU code for those instances of unknown feature values. Now for testing
	for(int i = 0; i < m_nodeIds.size(); i++)
	{
		int nid = m_nodeIds[i];
		if(nid == -1 || nid > preMaxNodeId)//processed node (i.e. leaf node or new node)
			continue;
		//newly constructed leaf node
		if(tree.nodes[nid]->rightChildId == LEAFNODE)
		{
			m_nodeIds[i] = -1;
		}
		else
		{
			map<int, pair<int, int> >::iterator it = mapPidCid.find(nid);
			m_nodeIds[i] = it->second.first;//by default the instance with unknown feature value going to left child

			PROCESS_ERROR(it != mapPidCid.end());
		}
	}
	//testing. Compute results from GPUs with those from CPUs
	manager.MemcpyDeviceToHost(manager.m_pInsIdToNodeId, insIdToNodeIdHost, sizeof(int) * manager.m_numofIns);
	for(int i = 0; i < manager.m_numofIns; i++)
	{
		PROCESS_ERROR(insIdToNodeIdHost[i] == m_nodeIds[i]);
	}
	delete []insIdToNodeIdHost;
	//################################# end
	#endif

	//update new splittable nodes
	int numofNewSplittableNode = -1;
	manager.MemcpyDeviceToHost(snManager.m_pNumofNewNode, &numofNewSplittableNode, sizeof(int));
	dim3 dimGridThreadForEachNewSN;
	conf.ComputeBlock(numofNewSplittableNode, dimGridThreadForEachNewSN);
	int sharedMemSizeNSN = 1;

	//reset nodeId to bufferId
	manager.Memset(manager.m_pSNIdToBuffId, -1, sizeof(int) * manager.m_maxNumofSplittable);
	manager.Memset(manager.m_pNumofBuffId, 0, sizeof(int));
	//reset nodeStat
	manager.Memset(manager.m_pSNodeStat, 0, sizeof(nodeStat) * manager.m_maxNumofSplittable);
	UpdateNewSplittable<<<dimGridThreadForEachNewSN, sharedMemSizeNSN>>>(
								  snManager.m_pNewSplittableNode, snManager.m_pNewNodeStat, manager.m_pSNIdToBuffId,
			   	   	   	   	   	  manager.m_pSNodeStat, snManager.m_pNumofNewNode, manager.m_pBuffIdVec, manager.m_pNumofBuffId,
			   	   	   	   	   	  manager.m_maxNumofSplittable, manager.m_nSNLock);
	manager.MemcpyDeviceToDevice(snManager.m_pNewSplittableNode, manager.m_pSplittableNode, sizeof(TreeNode) * manager.m_maxNumofSplittable);

	#ifdef _COMPARE_HOST
	//##################################### cpu code. new for testing
	mapNodeIdToBufferPos.clear();

	UpdateNodeStat(newSplittableNode, newNodeStat);

	splittableNode.clear();
	splittableNode = newSplittableNode;

	//compare results from GPU and those from CPU
	//nid to buffer id to obtain nodeStat for comparison
	int *pHostSNIdToBuffId = new int[manager.m_maxNumofSplittable];
	nodeStat *pSNodeStat = new nodeStat[manager.m_maxNumofSplittable];
	TreeNode *pNewSNode = new TreeNode[manager.m_maxNumofSplittable];
	int numofNewNode = -1;
	manager.MemcpyDeviceToHost(manager.m_pSNIdToBuffId, pHostSNIdToBuffId, sizeof(int) * manager.m_maxNumofSplittable);
	manager.MemcpyDeviceToHost(manager.m_pSNodeStat, pSNodeStat, sizeof(nodeStat) * manager.m_maxNumofSplittable);
	manager.MemcpyDeviceToHost(manager.m_pSplittableNode, pNewSNode, sizeof(TreeNode) * manager.m_maxNumofSplittable);
	manager.MemcpyDeviceToHost(snManager.m_pNumofNewNode, &numofNewNode, sizeof(int));
	PROCESS_ERROR(numofNewNode == newSplittableNode.size());
	for(int i = 0; i < newSplittableNode.size(); i++)
	{
		int nid = newSplittableNode[i]->nodeId;
		PROCESS_ERROR(nid == pNewSNode[i].nodeId);
		int sfid = newSplittableNode[i]->featureId;
		if(sfid != pNewSNode[i].featureId)
		{
			cout << sfid << " v.s. " << pNewSNode[i].featureId << endl;
			cout << "oh shit" << endl;
			exit(0);
		}
		PROCESS_ERROR(sfid == pNewSNode[i].featureId);
		int buffPos = pHostSNIdToBuffId[nid];//########### here might need to use hash function (commented on 24 June 16:09)
		PROCESS_ERROR(buffPos >= 0);
		int buffPosHost = mapNodeIdToBufferPos[nid];
		PROCESS_ERROR(pSNodeStat[buffPos].sum_gd == m_nodeStat[buffPosHost].sum_gd);
		PROCESS_ERROR(pSNodeStat[buffPos].sum_hess == m_nodeStat[buffPosHost].sum_hess);
	}
	delete []pHostSNIdToBuffId;
	delete []pSNodeStat;
	delete []pNewSNode;
	//################################## end
	#endif
}
