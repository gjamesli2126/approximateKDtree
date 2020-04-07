/* -*- mode: c -*- */
/*************************************************************************************************
 * Copyright (C) 2017, Nikhil Hegde, Jianqiao Liu, Kirshanthan Sundararajah, Milind Kulkarni, and 
 * Purdue University. All Rights Reserved. See Copyright.txt
*************************************************************************************************/

#include <cuda.h>
#include <stdio.h>
#include "../../../common/util_common.h"

#include "bh_kernel.h"

__global__ void init_kernel(void) {

}


__global__ void pre_compute_force_gpu(bh_gpu_tree root, Point* points, int npoints, float eps_squared, float dthf, int step, bool* relation_matrix, int start, int end)  {
	
	unsigned int i, pidx, j;
	int cur_node_index;
  
	Vec a_prev;
	Vec p_cofm;
	Vec p_acc;
	Vec p_vel;
	Vec delta_v;
	Vec dr;
	float drsq;
	float idr;
	float nphi;
	float scale;
	float ropensq;
	
	gpu_node0 cur_node0;
	gpu_node1 cur_node1;
	gpu_node2 cur_node2;

	#ifdef TRACK_TRAVERSALS
	int nodes_accessed;
	#endif
	
	int stk[128];
	int stk_top;
	int sp; 

#define STACK_INIT() sp = 1; \
	stk[sp] = 0;
#define STACK_POP() sp -= 1; 
#define STACK_PUSH() sp += 1; 
#define STACK_TOP_NODE_INDEX stk[sp]

	// loop over all points for this node
	for(pidx = blockIdx.x*blockDim.x + threadIdx.x + start; pidx < end; pidx += gridDim.x*blockDim.x) {
				
		// Cache this threads point
		//p_mass = points[pidx].mass;
		p_cofm = points[pidx].cofm;
		p_acc = points[pidx].acc;
		#ifdef TRACK_TRAVERSALS
		nodes_accessed = 0;
		#endif
		a_prev = p_acc;
		p_acc.x = 0.0;
		p_acc.y = 0.0;
		p_acc.z = 0.0;

		STACK_INIT();

		while(sp >= 1) {
			cur_node_index = STACK_TOP_NODE_INDEX;		

			if (root.nodes3[cur_node_index].depth == SPLICE_DEPTH) {
				relation_matrix[root.nodes3[cur_node_index].pre_id * npoints + pidx] = 1;
			}	
			STACK_POP();

			#ifdef TRACK_TRAVERSALS
			nodes_accessed++;
			#endif
			//CUR_NODE0 = params.root.nodes0[cur_node_index];
			dr.x = root.nodes0[cur_node_index].cofm.x - p_cofm.x;
			dr.y = root.nodes0[cur_node_index].cofm.y - p_cofm.y;
			dr.z = root.nodes0[cur_node_index].cofm.z - p_cofm.z;
			drsq = dr.x*dr.x + dr.y*dr.y + dr.z*dr.z;
			ropensq = root.nodes1[cur_node_index].ropen * root.nodes1[cur_node_index].ropen;
			 
			//params.root.nodes1[cur_node_index] = params.root.nodes1[cur_node_index];
			if(drsq < ropensq) {
				if (root.nodes0[cur_node_index].leafNode == false) {			
					if (root.nodes3[cur_node_index].depth < SPLICE_DEPTH) {
						if (root.nodes2[cur_node_index].right != -1) {
							STACK_PUSH();
							STACK_TOP_NODE_INDEX = root.nodes2[cur_node_index].right;
						}
						if (root.nodes2[cur_node_index].left != -1) {
							STACK_PUSH();
							STACK_TOP_NODE_INDEX = root.nodes2[cur_node_index].left;
						}
					}
				} else {
					if(points[pidx].id != root.nodes0[cur_node_index].point_id) {
						//drsq_2 = drsq + epssq;
						drsq += 2*eps_squared;
						idr = rsqrtf(drsq); //1.0 / sqrt(drsq);
						nphi = root.nodes1[cur_node_index].mass * idr;
						scale = nphi * idr *idr;

						p_acc.x += dr.x*scale;
						p_acc.y += dr.y*scale;
						p_acc.z += dr.z*scale;
					}
				}
			} else {
				//drsq_2 = drsq + epssq;
				drsq += 2*eps_squared;
				idr = rsqrtf(drsq); //1.0 / sqrt(drsq);
				nphi = root.nodes1[cur_node_index].mass * idr;
				scale = nphi * idr * idr;
							
				p_acc.x += dr.x*scale;
				p_acc.y += dr.y*scale;
				p_acc.z += dr.z*scale;
			}
		}

	  	p_vel = points[pidx].vel;
		if(step > 0) {
			
		  delta_v.x = (p_acc.x - a_prev.x) * dthf;
		  delta_v.y = (p_acc.y - a_prev.y) * dthf;
		  delta_v.z = (p_acc.z - a_prev.z) * dthf;
		  
		  p_vel.x = p_vel.x + delta_v.x;
		  p_vel.y = p_vel.y + delta_v.y;
		  p_vel.z = p_vel.z + delta_v.z;
		}
	       
		// Write cached point back to tree
//		points[pidx].vel = p_vel;
//		points[pidx].acc = p_acc;
//		#ifdef TRACK_TRAVERSALS
//		points[pidx].num_nodes_traversed = nodes_accessed;
//		#endif
	}	
}


__global__ void compute_force_gpu(bh_gpu_tree root, Point* points, int* gpu_buffer, int npoints, float eps_squared, float dthf, int step) {
	
	unsigned int i, pidx, j;
	int cur_node_index;
  
	Vec a_prev;
	Vec p_cofm;
	Vec p_acc;
	Vec p_vel;
	Vec delta_v;
	Vec dr;
	float drsq;
	float idr;
	float nphi;
	float scale;
	float ropensq;
	
	gpu_node0 cur_node0;
	gpu_node1 cur_node1;
	gpu_node2 cur_node2;

	#ifdef TRACK_TRAVERSALS
	int nodes_accessed;
	#endif

	__shared__ int SP[NUM_OF_WARPS_PER_BLOCK];
#define sp SP[WARP_INDEX]
	
	__shared__ int stk[NUM_OF_WARPS_PER_BLOCK][128];
	int stk_top;

	bool cond, status;
    bool opt1, opt2;
	int critical;
	unsigned int vote_left;
	unsigned int vote_right;
	unsigned int num_left;
	unsigned int num_right;

#define STACK_INIT() sp = 1; \
	stk[WARP_INDEX][sp] = 0;
#define STACK_POP() sp -= 1; 
#define STACK_PUSH() sp += 1; 
#define STACK_TOP_NODE_INDEX stk[WARP_INDEX][sp]

	// loop over all points for this node
	for(i = blockIdx.x*blockDim.x + threadIdx.x; i < npoints; i += gridDim.x*blockDim.x) {
				
		// Cache this threads point
		//p_mass = points[pidx].mass;
		pidx = gpu_buffer[i];
		p_cofm = points[pidx].cofm;
		p_acc = points[pidx].acc;
		#ifdef TRACK_TRAVERSALS
		nodes_accessed = 0;
		#endif
		a_prev = p_acc;
		p_acc.x = 0.0;
		p_acc.y = 0.0;
		p_acc.z = 0.0;

		STACK_INIT();
		status = 1;
		critical = 127;
		cond = 1;

		while(sp >= 1) {
			cur_node_index = STACK_TOP_NODE_INDEX;			
			if (status == 0 && critical >= sp) {
				status = 1;
			}	
			STACK_POP();

			if (status == 1) {
				#ifdef TRACK_TRAVERSALS
				nodes_accessed++;
				#endif
				//CUR_NODE0 = params.root.nodes0[cur_node_index];
				dr.x = root.nodes0[cur_node_index].cofm.x - p_cofm.x;
				dr.y = root.nodes0[cur_node_index].cofm.y - p_cofm.y;
				dr.z = root.nodes0[cur_node_index].cofm.z - p_cofm.z;
				drsq = dr.x*dr.x + dr.y*dr.y + dr.z*dr.z;
				ropensq = root.nodes1[cur_node_index].ropen * root.nodes1[cur_node_index].ropen;
				 
				cond = drsq < ropensq;
				critical = sp;
				if (!__any(cond)) {
					drsq += 2*eps_squared;
					idr = rsqrtf(drsq); //1.0 / sqrt(drsq);
					nphi = root.nodes1[cur_node_index].mass * idr;
					scale = nphi * idr * idr;
								
					p_acc.x += dr.x*scale;
					p_acc.y += dr.y*scale;
					p_acc.z += dr.z*scale;
					continue;
				}

				if(!cond) {
					drsq += 2*eps_squared;
					idr = rsqrtf(drsq); //1.0 / sqrt(drsq);
					nphi = root.nodes1[cur_node_index].mass * idr;
					scale = nphi * idr * idr;
								
					p_acc.x += dr.x*scale;
					p_acc.y += dr.y*scale;
					p_acc.z += dr.z*scale;
					
					status = 0;
				} else {
					if (root.nodes0[cur_node_index].leafNode == false) {			
						if (root.nodes2[cur_node_index].right != -1) {
							STACK_PUSH();
							STACK_TOP_NODE_INDEX = root.nodes2[cur_node_index].right;
						}
						if (root.nodes2[cur_node_index].left != -1) {
							STACK_PUSH();
							STACK_TOP_NODE_INDEX = root.nodes2[cur_node_index].left;
						}
					} else {
						if(points[pidx].id != root.nodes0[cur_node_index].point_id) {
							//drsq_2 = drsq + epssq;
							drsq += 2*eps_squared;
							idr = rsqrtf(drsq); //1.0 / sqrt(drsq);
							nphi = root.nodes1[cur_node_index].mass * idr;
							scale = nphi * idr *idr;

							p_acc.x += dr.x*scale;
							p_acc.y += dr.y*scale;
							p_acc.z += dr.z*scale;
						}
					}
				} 
			}
		}

	  	p_vel = points[pidx].vel;
		if(step > 0) {
			
		  delta_v.x = (p_acc.x - a_prev.x) * dthf;
		  delta_v.y = (p_acc.y - a_prev.y) * dthf;
		  delta_v.z = (p_acc.z - a_prev.z) * dthf;
		  
		  p_vel.x = p_vel.x + delta_v.x;
		  p_vel.y = p_vel.y + delta_v.y;
		  p_vel.z = p_vel.z + delta_v.z;
		}
	       
		// Write cached point back to tree
		points[pidx].vel = p_vel;
		points[pidx].acc = p_acc;
		#ifdef TRACK_TRAVERSALS
		points[pidx].num_nodes_traversed = nodes_accessed;
		#endif
	}	
}




