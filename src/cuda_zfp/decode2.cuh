#ifndef CUZFP_DECODE2_CUH
#define CUZFP_DECODE2_CUH

#include "shared.h"
#include "decode.cuh"
#include "type_info.cuh"

namespace cuZFP {

template<typename Scalar> 
__device__ __host__ inline 
void scatter_partial2(const Scalar* q, Scalar* p, int nx, int ny, int sx, int sy)
{
  uint x, y;
  for (y = 0; y < ny; y++, p += sy - nx * sx, q += 4 - nx)
    for (x = 0; x < nx; x++, p += sx, q++)
      *p = *q;
}

template<typename Scalar> 
__device__ __host__ inline 
void scatter2(const Scalar* q, Scalar* p, int sx, int sy)
{
  uint x, y;
  for (y = 0; y < 4; y++, p += sy - 4 * sx)
    for (x = 0; x < 4; x++, p += sx)
      *p = *q++;
}


template<class Scalar, int BlockSize>
__global__
void
cudaDecode2(Word *blocks,
            Scalar *out,
            const uint2 dims,
            const uint2 padded_dims,
            uint maxbits)
{
  typedef unsigned long long int ull;
  const ull blockId = blockIdx.x +
                      blockIdx.y * gridDim.x +
                      gridDim.x * gridDim.y * blockIdx.z;

  // each thread gets a block so the block index is 
  // the global thread index
  const ull block_idx = blockId * blockDim.x + threadIdx.x;
  
  const int total_blocks = (padded_dims.x * padded_dims.y) / 16; 
  
  if(block_idx >= total_blocks) 
  {
    return;
  }

  BlockReader<BlockSize> reader(blocks, maxbits, block_idx, total_blocks);
 
  Scalar result[BlockSize];
  memset(result, 0, sizeof(Scalar) * BlockSize);

  zfp_decode(reader, result, maxbits);

  // logical block dims
  uint2 block_dims;
  block_dims.x = padded_dims.x >> 2; 
  block_dims.y = padded_dims.y >> 2; 
  // logical pos in 3d array
  uint2 block;
  block.x = (block_idx % block_dims.x) * 4; 
  block.y = ((block_idx/ block_dims.x) % block_dims.y) * 4; 
  
  // default strides
  int sx = 1;
  int sy = dims.x;
  uint offset = block.x * sx + block.y * sy; 

  bool partial = false;
  if(block.x + 4 > dims.x) partial = true;
  if(block.y + 4 > dims.y) partial = true;
  if(partial)
  {
    const uint nx = block.x + 4 > dims.x ? dims.x - block.x : 4;
    const uint ny = block.y + 4 > dims.y ? dims.y - block.y : 4;
    scatter_partial2(result, out + offset, nx, ny, sx, sy);
  }
  else
  {
    scatter2(result, out + offset, sx, sy);
  }
}

template<class Scalar>
size_t decode2launch(uint2 dims, 
                     Word *stream,
                     Scalar *d_data,
                     uint maxbits)
{
  const int cuda_block_size = 128;
  dim3 block_size;
  block_size = dim3(cuda_block_size, 1, 1);
  
  uint2 zfp_pad(dims); 
  // ensure that we have block sizes
  // that are a multiple of 4
  if(zfp_pad.x % 4 != 0) zfp_pad.x += 4 - dims.x % 4;
  if(zfp_pad.y % 4 != 0) zfp_pad.y += 4 - dims.y % 4;

  const int zfp_blocks = (zfp_pad.x * zfp_pad.y) / 16; 

  
  //
  // we need to ensure that we launch a multiple of the 
  // cuda block size
  //
  int block_pad = 0; 
  if(zfp_blocks % cuda_block_size != 0)
  {
    block_pad = cuda_block_size - zfp_blocks % cuda_block_size; 
  }


  size_t stream_bytes = calc_device_mem2d(zfp_pad, maxbits);
  size_t total_blocks = block_pad + zfp_blocks;
  dim3 grid_size = calculate_grid_size(total_blocks, CUDA_BLK_SIZE_2D);

  // setup some timing code
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  cudaEventRecord(start);

  cudaDecode2<Scalar, 16> << < grid_size, block_size >> >
    (stream,
		 d_data,
     dims,
     zfp_pad,
     maxbits);

  cudaEventRecord(stop);
  cudaEventSynchronize(stop);
	cudaStreamSynchronize(0);

  float miliseconds = 0;
  cudaEventElapsedTime(&miliseconds, start, stop);
  float seconds = miliseconds / 1000.f;
  printf("Decode elapsed time: %.5f (s)\n", seconds);
  float rate = (float(dims.x * dims.y) * sizeof(Scalar) ) / seconds;
  rate /= 1024.f;
  rate /= 1024.f;
  rate /= 1024.f;
  printf("# decode2 rate: %.2f (GB / sec) %d\n", rate, maxbits);
  return stream_bytes;
}

template<class Scalar>
size_t decode2(uint2 dims, 
             Word *stream,
             Scalar *d_data,
             uint maxbits)
{
	return decode2launch<Scalar>(dims, stream, d_data, maxbits);
}

} // namespace cuZFP

#endif