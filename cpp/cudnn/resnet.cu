#include <chrono>
#include <iostream>

// https://stackoverflow.com/a/44760897
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cudnn.h>
#include <device_launch_parameters.h> // fix blockIdx not found
#include <random>

#include "helper_cuda.h"
#include "layers.h"
#include "readubyte.h"

// Block width for CUDA kernels
// https://stackoverflow.com/questions/9985912/how-do-i-choose-grid-and-block-dimensions-for-cuda-kernels
#define BW 128

/**
 * Computes ceil(x / y) for integral nonnegative values.
 */
static inline unsigned int RoundUp(unsigned int numerator, unsigned int denominator) {
    return (numerator + denominator - 1) / denominator;
}

///////////////////////////////////////////////////////////////////////////////////////////
// GPU Kernels

/**
 * Fills a floating-point array with ones.
 *
 * @param vec The array to fill.
 * @param size The number of elements in the array.
 */
__global__ void FillOnes(float *vec, int size) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= size)
        return;

    vec[idx] = 1.0f;
}

/**
 * Computes the backpropagation results of the Softmax loss for each result in a batch.
 * Uses the softmax values obtained from forward propagation to compute the difference.
 *
 * @param label The training batch label values.
 * @param num_labels The number of possible labels.
 * @param batch_size The size of the trained batch.
 * @param diff The resulting gradient.
 */
__global__ void
SoftmaxLossBackprop(const float *label, int num_labels, int batch_size, float *diff) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= batch_size)
        return;

    const int label_value = static_cast<int>(label[idx]);

    // For each item in the batch, decrease the result of the label's value by 1
    diff[idx * num_labels + label_value] -= 1.0f;
}

///////////////////////////////////////////////////////////////////////////////////////////
// CUDNN/CUBLAS training context

//struct TrainingContext {
//    cudnnHandle_t cudnnHandle;
//    cublasHandle_t cublasHandle;
//
//    // these are all storage tensors (e.g. src and dst)
//    cudnnTensorDescriptor_t dataTensor, conv1Tensor, conv1BiasTensor, pool1Tensor, conv2Tensor,
//        conv2BiasTensor, pool2Tensor, fc1Tensor, fc2Tensor;
//
//    // i.e. convolution kernel
//    cudnnFilterDescriptor_t conv1filterDesc, conv2filterDesc;
//
//    cudnnConvolutionDescriptor_t conv1Desc, conv2Desc;
//    cudnnConvolutionFwdAlgo_t conv1algo, conv2algo;
//    // backward filter algo
//    cudnnConvolutionBwdFilterAlgo_t conv1bwfalgo, conv2bwfalgo;
//
//    // cudnnConvolutionBwdDataAlgo_t is an enumerated type
//    // that exposes the different algorithms available to execute the backward data convolution
//    // operation.
//    cudnnConvolutionBwdDataAlgo_t conv2bwdalgo;
//
//    cudnnPoolingDescriptor_t poolDesc;
//
//    cudnnActivationDescriptor_t fc1Activation;
//
//    int m_gpuid;
//    int m_batchSize;
//    size_t m_workspaceSize;
//
//    FullyConnectedLayer &ref_fc1, &ref_fc2;
//
//    // Disable copying
//    TrainingContext &operator=(const TrainingContext &) = delete;
//    TrainingContext(const TrainingContext &) = delete;
//
//    TrainingContext(
//        int gpuid,
//        int batch_size,
//        ConvBiasLayer &conv1,
//        MaxPoolLayer &pool1,
//        ConvBiasLayer &conv2,
//        MaxPoolLayer &pool2,
//        FullyConnectedLayer &fc1,
//        FullyConnectedLayer &fc2)
//        : ref_fc1(fc1), ref_fc2(fc2), m_gpuid(gpuid), m_batchSize(batch_size) {
//
//        // Create CUBLAS and CUDNN handles
//        CHECK_CUDA_ERRORS(cudaSetDevice(gpuid));
//        CHECK_CUDA_ERRORS(cublasCreate(&cublasHandle));
//        CUDNN_CHECK(cudnnCreate(&cudnnHandle));
//
//        // Create tensor descriptors
//        CUDNN_CHECK(cudnnCreateTensorDescriptor(&dataTensor));
//        CUDNN_CHECK(cudnnCreateTensorDescriptor(&conv1Tensor));
//        CUDNN_CHECK(cudnnCreateTensorDescriptor(&conv1BiasTensor));
//        CUDNN_CHECK(cudnnCreateTensorDescriptor(&pool1Tensor));
//        CUDNN_CHECK(cudnnCreateTensorDescriptor(&conv2Tensor));
//        CUDNN_CHECK(cudnnCreateTensorDescriptor(&conv2BiasTensor));
//        CUDNN_CHECK(cudnnCreateTensorDescriptor(&pool2Tensor));
//        CUDNN_CHECK(cudnnCreateTensorDescriptor(&fc1Tensor));
//        CUDNN_CHECK(cudnnCreateTensorDescriptor(&fc2Tensor));
//
//        CUDNN_CHECK(cudnnCreateActivationDescriptor(&fc1Activation));
//
//        CUDNN_CHECK(cudnnCreateFilterDescriptor(&conv1filterDesc));
//        CUDNN_CHECK(cudnnCreateFilterDescriptor(&conv2filterDesc));
//
//        CUDNN_CHECK(cudnnCreateConvolutionDescriptor(&conv1Desc));
//        CUDNN_CHECK(cudnnCreateConvolutionDescriptor(&conv2Desc));
//
//        CUDNN_CHECK(cudnnCreatePoolingDescriptor(&poolDesc));
//        // Set tensor descriptor sizes
//        CUDNN_CHECK(cudnnSetTensor4dDescriptor(
//            /*tensorDesc*/ conv1BiasTensor,
//            /*format*/ CUDNN_TENSOR_NCHW,
//            /*dataType*/ CUDNN_DATA_FLOAT,
//            /*n*/ 1,
//            /*c*/ conv1.out_channels,
//            /*h*/ 1,
//            /*w*/ 1));
//
//        CUDNN_CHECK(cudnnSetTensor4dDescriptor(
//            conv2BiasTensor, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, 1, conv2.out_channels, 1, 1));
//
//        CUDNN_CHECK(cudnnSetPooling2dDescriptor(
//            poolDesc,
//            CUDNN_POOLING_MAX,
//            CUDNN_PROPAGATE_NAN,
//            /*windowHeight*/ pool1.size,
//            /*windowWidth*/ pool1.size,
//            /*verticalPadding*/ 0,
//            /*horizontalPadding*/ 0,
//            /*verticalStride*/ pool1.stride,
//            /*horizontalStride*/ pool1.stride));
//        CUDNN_CHECK(cudnnSetTensor4dDescriptor(
//            pool2Tensor,
//            CUDNN_TENSOR_NCHW,
//            CUDNN_DATA_FLOAT,
//            batch_size,
//            conv2.out_channels,
//            conv2.out_height / pool2.stride,
//            conv2.out_width / pool2.stride));
//
//        CUDNN_CHECK(cudnnSetTensor4dDescriptor(
//            fc1Tensor, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, batch_size, fc1.outputs, 1, 1));
//
//        CUDNN_CHECK(cudnnSetTensor4dDescriptor(
//            fc2Tensor, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, batch_size, fc2.outputs, 1, 1));
//
//        CUDNN_CHECK(cudnnSetActivationDescriptor(
//            fc1Activation, CUDNN_ACTIVATION_RELU, CUDNN_PROPAGATE_NAN, /*coef*/ 0.0));
//
//        // Set convolution tensor sizes and compute workspace size
//        size_t workspace = 0;
//        workspace = std::max(
//            workspace,
//            SetFwdConvolutionTensors(
//                conv1, dataTensor, conv1Tensor, conv1filterDesc, conv1Desc, conv1algo));
//        workspace = std::max(
//            workspace,
//            SetBwdConvolutionTensors(
//                dataTensor,
//                conv1Tensor,
//                conv1filterDesc,
//                conv1Desc,
//                /**f[ilter]algo*/ &conv1bwfalgo,
//                /**d[ata]algo*/ nullptr)); // TODO: what is a data algo?
//
//        workspace = std::max(
//            workspace,
//            SetFwdConvolutionTensors(
//                conv2, pool1Tensor, conv2Tensor, conv2filterDesc, conv2Desc, conv2algo));
//        workspace = std::max(
//            workspace,
//            SetBwdConvolutionTensors(
//                pool1Tensor,
//                conv2Tensor,
//                conv2filterDesc,
//                conv2Desc,
//                &conv2bwfalgo,
//                &conv2bwdalgo));
//
//        // The workspace is allocated later (if necessary)
//        m_workspaceSize = workspace;
//    }
//
//    ~TrainingContext() {
//        CHECK_CUDA_ERRORS(cudaSetDevice(m_gpuid));
//
//        CHECK_CUDA_ERRORS(cublasDestroy(cublasHandle));
//        CUDNN_CHECK(cudnnDestroy(cudnnHandle));
//        for (auto tensor :
//             {dataTensor,
//              conv1Tensor,
//              conv1BiasTensor,
//              pool1Tensor,
//              conv2Tensor,
//              conv2BiasTensor,
//              pool2Tensor,
//              fc1Tensor,
//              fc2Tensor}) {
//            CUDNN_CHECK(cudnnDestroyTensorDescriptor(tensor));
//        }
//
//        CUDNN_CHECK(cudnnDestroyActivationDescriptor(fc1Activation));
//        CUDNN_CHECK(cudnnDestroyFilterDescriptor(conv1filterDesc));
//        CUDNN_CHECK(cudnnDestroyFilterDescriptor(conv2filterDesc));
//        CUDNN_CHECK(cudnnDestroyConvolutionDescriptor(conv1Desc));
//        CUDNN_CHECK(cudnnDestroyConvolutionDescriptor(conv2Desc));
//        CUDNN_CHECK(cudnnDestroyPoolingDescriptor(poolDesc));
//    }
//
//    size_t SetFwdConvolutionTensors(
//        ConvBiasLayer &conv,
//        cudnnTensorDescriptor_t &srcTensorDesc,
//        cudnnTensorDescriptor_t &dstTensorDesc,
//        cudnnFilterDescriptor_t &filterDesc,
//        cudnnConvolutionDescriptor_t &convDesc,
//        cudnnConvolutionFwdAlgo_t &algo) {
//        size_t sizeInBytes = 0;
//
//        int n = m_batchSize;
//        int c = conv.in_channels;
//        int h = conv.in_height;
//        int w = conv.in_width;
//
//        CUDNN_CHECK(cudnnSetTensor4dDescriptor(
//            srcTensorDesc, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, n, c, h, w));
//
//        CUDNN_CHECK(cudnnSetFilter4dDescriptor(
//            filterDesc,
//            CUDNN_DATA_FLOAT,
//            CUDNN_TENSOR_NCHW,
//            conv.out_channels,
//            conv.in_channels,
//            conv.kernel_size,
//            conv.kernel_size));
//
//        CUDNN_CHECK(cudnnSetConvolution2dDescriptor(
//            convDesc,
//            /*pad_h*/ 0,
//            /*pad_w*/ 0,
//            /*u*/ 1, // TODO wtf is uv
//            /*v*/ 1,
//            /*dilation_h*/ 1,
//            /*dilation_w*/ 1,
//            CUDNN_CROSS_CORRELATION,
//            CUDNN_DATA_FLOAT));
//
//        // Find dimension of convolution output
//        CUDNN_CHECK(cudnnGetConvolution2dForwardOutputDim(
//            convDesc, srcTensorDesc, filterDesc, &n, &c, &h, &w));
//
//        CUDNN_CHECK(cudnnSetTensor4dDescriptor(
//            dstTensorDesc, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, n, c, h, w));
//        CUDNN_CHECK(cudnnGetConvolutionForwardAlgorithm(
//            cudnnHandle,
//            srcTensorDesc,
//            filterDesc,
//            convDesc,
//            dstTensorDesc,
//            CUDNN_CONVOLUTION_FWD_PREFER_FASTEST,
//            /*memoryLimitInBytes*/ 0,
//            &algo));
//
//        CUDNN_CHECK(cudnnGetConvolutionForwardWorkspaceSize(
//            cudnnHandle, srcTensorDesc, filterDesc, convDesc, dstTensorDesc, algo, &sizeInBytes));
//
//        return sizeInBytes;
//    }
//
//    void ForwardPropagation(
//        float *data,
//        float *conv1,
//        float *pool1,
//        float *conv2,
//        float *pool2,
//        float *fc1,
//        float *fc1relu,
//        float *fc2,
//        float *result,
//        float *pconv1,
//        float *pconv1bias,
//        float *pconv2,
//        float *pconv2bias,
//        float *pfc1,
//        float *pfc1bias,
//        float *pfc2,
//        float *pfc2bias,
//        void *workspace,
//        float *onevec) {
//        float alpha = 1.0f, beta = 0.0f;
//        CHECK_CUDA_ERRORS(cudaSetDevice(m_gpuid));
//
//        // Conv1 layer
//        CUDNN_CHECK(cudnnConvolutionForward(
//            cudnnHandle,
//            &alpha,
//            dataTensor,
//            data,
//            conv1filterDesc,
//            pconv1,
//            conv1Desc,
//            conv1algo,
//            workspace,
//            m_workspaceSize,
//            &beta,
//            conv1Tensor,
//            conv1));
//        CUDNN_CHECK(cudnnAddTensor(
//            cudnnHandle, &alpha, conv1BiasTensor, pconv1bias, &alpha, conv1Tensor, conv1));
//
//        // Pool1 layer
//        CUDNN_CHECK(cudnnPoolingForward(
//            cudnnHandle, poolDesc, &alpha, conv1Tensor, conv1, &beta, pool1Tensor, pool1));
//
//        // Conv2 layer
//        CUDNN_CHECK(cudnnConvolutionForward(
//            cudnnHandle,
//            &alpha,
//            pool1Tensor,
//            pool1,
//            conv2filterDesc,
//            pconv2,
//            conv2Desc,
//            conv2algo,
//            workspace,
//            m_workspaceSize,
//            &beta,
//            conv2Tensor,
//            conv2));
//        CUDNN_CHECK(cudnnAddTensor(
//            cudnnHandle, &alpha, conv2BiasTensor, pconv2bias, &alpha, conv2Tensor, conv2));
//
//        // Pool2 layer
//        CUDNN_CHECK(cudnnPoolingForward(
//            cudnnHandle, poolDesc, &alpha, conv2Tensor, conv2, &beta, pool2Tensor, pool2));
//
//        // FC1 layer
//        // Forward propagate neurons using weights (fc1 = pfc1'*pool2)
//        CHECK_CUDA_ERRORS(cublasSgemm(
//            cublasHandle,
//            CUBLAS_OP_T,
//            CUBLAS_OP_N,
//            ref_fc1.outputs,
//            m_batchSize,
//            ref_fc1.inputs,
//            &alpha,
//            pfc1,
//            ref_fc1.inputs,
//            pool2,
//            ref_fc1.inputs,
//            &beta,
//            fc1,
//            ref_fc1.outputs));
//        // Add bias using GEMM's "beta" (fc1 += pfc1bias*1_vec')
//        CHECK_CUDA_ERRORS(cublasSgemm(
//            cublasHandle,
//            CUBLAS_OP_N,
//            CUBLAS_OP_N,
//            ref_fc1.outputs,
//            m_batchSize,
//            1,
//            &alpha,
//            pfc1bias,
//            ref_fc1.outputs,
//            onevec,
//            1,
//            &alpha,
//            fc1,
//            ref_fc1.outputs));
//
//        // ReLU activation
//        CUDNN_CHECK(cudnnActivationForward(
//            cudnnHandle, fc1Activation, &alpha, fc1Tensor, fc1, &beta, fc1Tensor, fc1relu));
//
//        // FC2 layer
//        // Forward propagate neurons using weights (fc2 = pfc2'*fc1relu)
//        CHECK_CUDA_ERRORS(cublasSgemm(
//            cublasHandle,
//            CUBLAS_OP_T,
//            CUBLAS_OP_N,
//            ref_fc2.outputs,
//            m_batchSize,
//            ref_fc2.inputs,
//            &alpha,
//            pfc2,
//            ref_fc2.inputs,
//            fc1relu,
//            ref_fc2.inputs,
//            &beta,
//            fc2,
//            ref_fc2.outputs));
//        // Add bias using GEMM's "beta" (fc2 += pfc2bias*1_vec')
//        CHECK_CUDA_ERRORS(cublasSgemm(
//            cublasHandle,
//            CUBLAS_OP_N,
//            CUBLAS_OP_N,
//            ref_fc2.outputs,
//            m_batchSize,
//            1,
//            &alpha,
//            pfc2bias,
//            ref_fc2.outputs,
//            onevec,
//            1,
//            &alpha,
//            fc2,
//            ref_fc2.outputs));
//
//        // Softmax loss
//        CUDNN_CHECK(cudnnSoftmaxForward(
//            cudnnHandle,
//            CUDNN_SOFTMAX_ACCURATE,
//            CUDNN_SOFTMAX_MODE_CHANNEL,
//            &alpha,
//            fc2Tensor,
//            fc2,
//            &beta,
//            fc2Tensor,
//            result));
//    }
//
//    size_t SetBwdConvolutionTensors(
//        cudnnTensorDescriptor_t &srcTensorDesc,
//        cudnnTensorDescriptor_t &dstTensorDesc,
//        cudnnFilterDescriptor_t &filterDesc,
//        cudnnConvolutionDescriptor_t &convDesc,
//        cudnnConvolutionBwdFilterAlgo_t *falgo,
//        cudnnConvolutionBwdDataAlgo_t *dalgo) {
//        size_t sizeInBytes = 0, tmpsize = 0;
//
//        // If backprop filter algorithm was requested
//        if (falgo) {
//            CUDNN_CHECK(cudnnGetConvolutionBackwardFilterAlgorithm(
//                cudnnHandle,
//                srcTensorDesc,
//                dstTensorDesc,
//                convDesc,
//                filterDesc,
//                CUDNN_CONVOLUTION_BWD_FILTER_PREFER_FASTEST,
//                0,
//                falgo));
//
//            CUDNN_CHECK(cudnnGetConvolutionBackwardFilterWorkspaceSize(
//                cudnnHandle, srcTensorDesc, dstTensorDesc, convDesc, filterDesc, *falgo, &tmpsize));
//
//            sizeInBytes = std::max(sizeInBytes, tmpsize);
//        }
//
//        // If backprop data algorithm was requested
//        if (dalgo) {
//            CUDNN_CHECK(cudnnGetConvolutionBackwardDataAlgorithm(
//                cudnnHandle,
//                filterDesc,
//                dstTensorDesc,
//                convDesc,
//                srcTensorDesc,
//                CUDNN_CONVOLUTION_BWD_DATA_PREFER_FASTEST,
//                0,
//                dalgo));
//
//            CUDNN_CHECK(cudnnGetConvolutionBackwardDataWorkspaceSize(
//                cudnnHandle, filterDesc, dstTensorDesc, convDesc, srcTensorDesc, *dalgo, &tmpsize));
//
//            sizeInBytes = std::max(sizeInBytes, tmpsize);
//        }
//
//        return sizeInBytes;
//    }
//
//    void Backpropagation(
//        ConvBiasLayer &layer_conv1,
//        MaxPoolLayer &layer_pool1,
//        ConvBiasLayer &layer_conv2,
//        MaxPoolLayer &layer_pool2,
//        float *data,
//        float *labels,
//        float *conv1,
//        float *pool1,
//        float *conv2,
//        float *pool2,
//        float *fc1,
//        float *fc1relu,
//        float *fc2,
//        float *fc2smax,
//        float *dloss_data,
//        float *pconv1,
//        float *pconv1bias,
//        float *pconv2,
//        float *pconv2bias,
//        float *pfc1,
//        float *pfc1bias,
//        float *pfc2,
//        float *pfc2bias,
//        float *gconv1,
//        float *gconv1bias,
//        float *dpool1,
//        float *gconv2,
//        float *gconv2bias,
//        float *dconv2,
//        float *dpool2,
//        float *gfc1,
//        float *gfc1bias,
//        float *dfc1,
//        float *dfc1relu,
//        float *gfc2,
//        float *gfc2bias,
//        float *dfc2,
//        void *workspace,
//        float *onevec) {
//        float alpha = 1.0f, beta = 0.0f;
//
//        float scalVal = 1.0f / static_cast<float>(m_batchSize);
//
//        CHECK_CUDA_ERRORS(cudaSetDevice(m_gpuid));
//
//        // Initialization (using the training error function)
//        CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//            dloss_data,
//            fc2smax,
//            sizeof(float) * m_batchSize * ref_fc2.outputs,
//            cudaMemcpyDeviceToDevice));
//
//        // Softmax layer
//        // https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#kernels
//        SoftmaxLossBackprop<<<RoundUp(m_batchSize, BW), BW>>>(
//            labels, ref_fc2.outputs, m_batchSize, dloss_data);
//
//        // Accounting for batch size in SGD
//        CHECK_CUDA_ERRORS(
//            cublasSscal(cublasHandle, ref_fc2.outputs * m_batchSize, &scalVal, dloss_data, 1));
//
//        // FC2 layer
//        // Compute derivative with respect to weights: gfc2 = (fc1relu * dfc2smax')
//        CHECK_CUDA_ERRORS(cublasSgemm(
//            cublasHandle,
//            CUBLAS_OP_N,
//            CUBLAS_OP_T,
//            ref_fc2.inputs,
//            ref_fc2.outputs,
//            m_batchSize,
//            &alpha,
//            fc1relu,
//            ref_fc2.inputs,
//            dloss_data,
//            ref_fc2.outputs,
//            &beta,
//            gfc2,
//            ref_fc2.inputs));
//        // Compute derivative with respect to bias: gfc2bias = dfc2smax * 1_vec
//        CHECK_CUDA_ERRORS(cublasSgemv(
//            cublasHandle,
//            CUBLAS_OP_N,
//            ref_fc2.outputs,
//            m_batchSize,
//            &alpha,
//            dloss_data,
//            ref_fc2.outputs,
//            onevec,
//            1,
//            &beta,
//            gfc2bias,
//            1));
//        // Compute derivative with respect to data (for previous layer): pfc2*dfc2smax (500x10*10xN)
//        CHECK_CUDA_ERRORS(cublasSgemm(
//            cublasHandle,
//            CUBLAS_OP_N,
//            CUBLAS_OP_N,
//            ref_fc2.inputs,
//            m_batchSize,
//            ref_fc2.outputs,
//            &alpha,
//            pfc2,
//            ref_fc2.inputs,
//            dloss_data,
//            ref_fc2.outputs,
//            &beta,
//            dfc2,
//            ref_fc2.inputs));
//
//        // ReLU activation
//        CUDNN_CHECK(cudnnActivationBackward(
//            cudnnHandle,
//            fc1Activation,
//            &alpha,
//            fc1Tensor,
//            fc1relu,
//            fc1Tensor,
//            dfc2,
//            fc1Tensor,
//            fc1,
//            &beta,
//            fc1Tensor,
//            dfc1relu));
//
//        // FC1 layer
//        // Compute derivative with respect to weights: gfc1 = (pool2 * dfc1relu')
//        CHECK_CUDA_ERRORS(cublasSgemm(
//            cublasHandle,
//            CUBLAS_OP_N,
//            CUBLAS_OP_T,
//            ref_fc1.inputs,
//            ref_fc1.outputs,
//            m_batchSize,
//            &alpha,
//            pool2,
//            ref_fc1.inputs,
//            dfc1relu,
//            ref_fc1.outputs,
//            &beta,
//            gfc1,
//            ref_fc1.inputs));
//        // Compute derivative with respect to bias: gfc1bias = dfc1relu * 1_vec
//        CHECK_CUDA_ERRORS(cublasSgemv(
//            cublasHandle,
//            CUBLAS_OP_N,
//            ref_fc1.outputs,
//            m_batchSize,
//            &alpha,
//            dfc1relu,
//            ref_fc1.outputs,
//            onevec,
//            1,
//            &beta,
//            gfc1bias,
//            1));
//        // Compute derivative with respect to data (for previous layer): pfc1*dfc1relu
//        // (800x500*500xN)
//        CHECK_CUDA_ERRORS(cublasSgemm(
//            cublasHandle,
//            CUBLAS_OP_N,
//            CUBLAS_OP_N,
//            ref_fc1.inputs,
//            m_batchSize,
//            ref_fc1.outputs,
//            &alpha,
//            pfc1,
//            ref_fc1.inputs,
//            dfc1relu,
//            ref_fc1.outputs,
//            &beta,
//            dfc1,
//            ref_fc1.inputs));
//
//        // Pool2 layer
//        CUDNN_CHECK(cudnnPoolingBackward(
//            cudnnHandle,
//            poolDesc,
//            &alpha,
//            pool2Tensor,
//            pool2,
//            pool2Tensor,
//            dfc1,
//            conv2Tensor,
//            conv2,
//            &beta,
//            conv2Tensor,
//            dpool2));
//
//        // Conv2 layer
//        CUDNN_CHECK(cudnnConvolutionBackwardBias(
//            cudnnHandle, &alpha, conv2Tensor, dpool2, &beta, conv2BiasTensor, gconv2bias));
//
//        CUDNN_CHECK(cudnnConvolutionBackwardFilter(
//            cudnnHandle,
//            &alpha,
//            pool1Tensor,
//            pool1,
//            conv2Tensor,
//            dpool2,
//            conv2Desc,
//            conv2bwfalgo,
//            workspace,
//            m_workspaceSize,
//            &beta,
//            conv2filterDesc,
//            gconv2));
//
//        CUDNN_CHECK(cudnnConvolutionBackwardData(
//            cudnnHandle,
//            &alpha,
//            conv2filterDesc,
//            pconv2,
//            conv2Tensor,
//            dpool2,
//            conv2Desc,
//            conv2bwdalgo,
//            workspace,
//            m_workspaceSize,
//            &beta,
//            pool1Tensor,
//            dconv2));
//
//        // Pool1 layer
//        CUDNN_CHECK(cudnnPoolingBackward(
//            cudnnHandle,
//            poolDesc,
//            &alpha,
//            pool1Tensor,
//            pool1,
//            pool1Tensor,
//            dconv2,
//            conv1Tensor,
//            conv1,
//            &beta,
//            conv1Tensor,
//            dpool1));
//
//        // Conv1 layer
//        CUDNN_CHECK(cudnnConvolutionBackwardBias(
//            cudnnHandle, &alpha, conv1Tensor, dpool1, &beta, conv1BiasTensor, gconv1bias));
//
//        CUDNN_CHECK(cudnnConvolutionBackwardFilter(
//            cudnnHandle,
//            &alpha,
//            dataTensor,
//            data,
//            conv1Tensor,
//            dpool1,
//            conv1Desc,
//            conv1bwfalgo,
//            workspace,
//            m_workspaceSize,
//            &beta,
//            conv1filterDesc,
//            gconv1));
//
//        // No need for convBackwardData because there are no more layers below
//    }
//
//    void UpdateWeights(
//        float learning_rate,
//        ConvBiasLayer &conv1,
//        ConvBiasLayer &conv2,
//        float *pconv1,
//        float *pconv1bias,
//        float *pconv2,
//        float *pconv2bias,
//        float *pfc1,
//        float *pfc1bias,
//        float *pfc2,
//        float *pfc2bias,
//        float *gconv1,
//        float *gconv1bias,
//        float *gconv2,
//        float *gconv2bias,
//        float *gfc1,
//        float *gfc1bias,
//        float *gfc2,
//        float *gfc2bias) {
//        float alpha = -learning_rate;
//
//        CHECK_CUDA_ERRORS(cudaSetDevice(m_gpuid));
//
//        // Conv1
//        CHECK_CUDA_ERRORS(cublasSaxpy(
//            cublasHandle, static_cast<int>(conv1.pconv.size()), &alpha, gconv1, 1, pconv1, 1));
//        CHECK_CUDA_ERRORS(cublasSaxpy(
//            cublasHandle,
//            static_cast<int>(conv1.pbias.size()),
//            &alpha,
//            gconv1bias,
//            1,
//            pconv1bias,
//            1));
//
//        // Conv2
//        CHECK_CUDA_ERRORS(cublasSaxpy(
//            cublasHandle, static_cast<int>(conv2.pconv.size()), &alpha, gconv2, 1, pconv2, 1));
//        CHECK_CUDA_ERRORS(cublasSaxpy(
//            cublasHandle,
//            static_cast<int>(conv2.pbias.size()),
//            &alpha,
//            gconv2bias,
//            1,
//            pconv2bias,
//            1));
//
//        // Fully connected 1
//        CHECK_CUDA_ERRORS(cublasSaxpy(
//            cublasHandle, static_cast<int>(ref_fc1.pneurons.size()), &alpha, gfc1, 1, pfc1, 1));
//        CHECK_CUDA_ERRORS(cublasSaxpy(
//            cublasHandle,
//            static_cast<int>(ref_fc1.pbias.size()),
//            &alpha,
//            gfc1bias,
//            1,
//            pfc1bias,
//            1));
//
//        // Fully connected 2
//        CHECK_CUDA_ERRORS(cublasSaxpy(
//            cublasHandle, static_cast<int>(ref_fc2.pneurons.size()), &alpha, gfc2, 1, pfc2, 1));
//        CHECK_CUDA_ERRORS(cublasSaxpy(
//            cublasHandle,
//            static_cast<int>(ref_fc2.pbias.size()),
//            &alpha,
//            gfc2bias,
//            1,
//            pfc2bias,
//            1));
//    }
//};
//
/////////////////////////////////////////////////////////////////////////////////////////////
//// Main function
//
//int main(int argc, char **argv) {
//    size_t width, height, channels = 1;
//
//    // Open input data
//    printf("Reading input data\n");
//    auto FLAGS_train_images = "/home/maksim/dev_projects/pytorch_abstraction_comparison/data/mnist/"
//                              "train-images-idx3-ubyte";
//    auto FLAGS_train_labels = "/home/maksim/dev_projects/pytorch_abstraction_comparison/data/mnist/"
//                              "train-labels-idx1-ubyte";
//    auto FLAGS_test_images = "/home/maksim/dev_projects/pytorch_abstraction_comparison/data/mnist/"
//                             "t10k-images-idx3-ubyte";
//    auto FLAGS_test_labels = "/home/maksim/dev_projects/pytorch_abstraction_comparison/data/mnist/"
//                             "t10k-labels-idx1-ubyte";
//    int FLAGS_batch_size = 32;
//    int FLAGS_iterations = 100000;
//    int FLAGS_gpu = 1;
//    bool FLAGS_pretrained = false;
//    int FLAGS_random_seed = -1;
//    float FLAGS_learning_rate = 0.01;
//    float FLAGS_lr_gamma = 0.01;
//    float FLAGS_lr_power = 0.01;
//    int FLAGS_classify = 1000;
//
//    // Read dataset sizes
//    size_t train_size =
//        ReadUByteDataset(FLAGS_train_images, FLAGS_train_labels, nullptr, nullptr, width, height);
//    size_t test_size =
//        ReadUByteDataset(FLAGS_test_images, FLAGS_test_labels, nullptr, nullptr, width, height);
//    if (train_size == 0)
//        return 1;
//    // std::cout << "# train samples" << train_size << std::endl;
//
//    std::vector<uint8_t> train_images(train_size * width * height * channels),
//        train_labels(train_size);
//    std::vector<uint8_t> test_images(test_size * width * height * channels), test_labels(test_size);
//
//    // Read data from datasets
//    if (ReadUByteDataset(
//            FLAGS_train_images,
//            FLAGS_train_labels,
//            &train_images[0],
//            &train_labels[0],
//            width,
//            height) != train_size)
//        return 2;
//    if (ReadUByteDataset(
//            FLAGS_test_images,
//            FLAGS_test_labels,
//            &test_images[0],
//            &test_labels[0],
//            width,
//            height) != test_size)
//        return 3;
//
//    printf(
//        "Done. Training dataset size: %d, Test dataset size: %d\n",
//        (int)train_size,
//        (int)test_size);
//    printf("Batch size: %d, iterations: %d\n", FLAGS_batch_size, FLAGS_iterations);
//
//    // This code snippet saves a random image and its label
//    /*
//    std::random_device rd_image;
//    int random_image = rd_image() % train_size;
//    std::stringstream ss; ss << "image-" << (int)train_labels[random_image] << ".pgm";
//    SavePGMFile(&train_images[0] + random_image * width*height*channels, width, height,
//    ss.str().c_str());
//    */
//
//    // Choose GPU
//    int num_gpus;
//    CHECK_CUDA_ERRORS(cudaGetDeviceCount(&num_gpus));
//    if (FLAGS_gpu < 0 || FLAGS_gpu >= num_gpus) {
//        printf(
//            "ERROR: Invalid GPU ID %d (There are %d GPUs on this machine)\n", FLAGS_gpu, num_gpus);
//        return 4;
//    }
//
//    // Create the LeNet network architecture
//    ConvBiasLayer conv1((int)channels, 20, 5, (int)width, (int)height);
//    MaxPoolLayer pool1(2, 2);
//    ConvBiasLayer conv2(
//        conv1.out_channels, 50, 5, conv1.out_width / pool1.stride, conv1.out_height / pool1.stride);
//    MaxPoolLayer pool2(2, 2);
//    FullyConnectedLayer fc1(
//        (conv2.out_channels * conv2.out_width * conv2.out_height) / (pool2.stride * pool2.stride),
//        500);
//    FullyConnectedLayer fc2(fc1.outputs, 10);
//
//    // Initialize CUDNN/CUBLAS training context
//    TrainingContext context(FLAGS_gpu, FLAGS_batch_size, conv1, pool1, conv2, pool2, fc1, fc2);
//
//    // Determine initial network structure
//    bool bRet = true;
//    // if (FLAGS_pretrained) {
//    //     bRet = conv1.FromFile("conv1");
//    //     bRet &= conv2.FromFile("conv2");
//    //     bRet &= fc1.FromFile("ip1");
//    //     bRet &= fc2.FromFile("ip2");
//    // }
//    if (!bRet || !FLAGS_pretrained) {
//        // Create random network
//        std::random_device rd;
//        std::mt19937 gen(
//            FLAGS_random_seed < 0 ? rd() : static_cast<unsigned int>(FLAGS_random_seed));
//
//        // Xavier weight filling
//        float wconv1 = sqrt(3.0f / (conv1.kernel_size * conv1.kernel_size * conv1.in_channels));
//        std::uniform_real_distribution<> dconv1(-wconv1, wconv1);
//        float wconv2 = sqrt(3.0f / (conv2.kernel_size * conv2.kernel_size * conv2.in_channels));
//        std::uniform_real_distribution<> dconv2(-wconv2, wconv2);
//        float wfc1 = sqrt(3.0f / (fc1.inputs * fc1.outputs));
//        std::uniform_real_distribution<> dfc1(-wfc1, wfc1);
//        float wfc2 = sqrt(3.0f / (fc2.inputs * fc2.outputs));
//        std::uniform_real_distribution<> dfc2(-wfc2, wfc2);
//
//        // Randomize network
//        for (auto &&iter : conv1.pconv)
//            iter = static_cast<float>(dconv1(gen));
//        for (auto &&iter : conv1.pbias)
//            iter = static_cast<float>(dconv1(gen));
//        for (auto &&iter : conv2.pconv)
//            iter = static_cast<float>(dconv2(gen));
//        for (auto &&iter : conv2.pbias)
//            iter = static_cast<float>(dconv2(gen));
//        for (auto &&iter : fc1.pneurons)
//            iter = static_cast<float>(dfc1(gen));
//        for (auto &&iter : fc1.pbias)
//            iter = static_cast<float>(dfc1(gen));
//        for (auto &&iter : fc2.pneurons)
//            iter = static_cast<float>(dfc2(gen));
//        for (auto &&iter : fc2.pbias)
//            iter = static_cast<float>(dfc2(gen));
//    }
//
//    /////////////////////////////////////////////////////////////////////////////
//    // Create GPU data structures
//
//    // Forward propagation data
//    float *d_data, *d_labels, *d_conv1, *d_pool1, *d_conv2, *d_pool2, *d_fc1, *d_fc1relu, *d_fc2,
//        *d_fc2smax;
//    //                         Buffer    | Element       | N                   | C | H | W
//    //-----------------------------------------------------------------------------------------------------------------------------------------
//    CHECK_CUDA_ERRORS(
//        cudaMalloc(&d_data, sizeof(float) * context.m_batchSize * channels * height * width));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_labels, sizeof(float) * context.m_batchSize * 1 * 1 * 1));
//    CHECK_CUDA_ERRORS(cudaMalloc(
//        &d_conv1,
//        sizeof(float) * context.m_batchSize * conv1.out_channels * conv1.out_height *
//            conv1.out_width));
//    CHECK_CUDA_ERRORS(cudaMalloc(
//        &d_pool1,
//        sizeof(float) * context.m_batchSize * conv1.out_channels *
//            (conv1.out_height / pool1.stride) * (conv1.out_width / pool1.stride)));
//    CHECK_CUDA_ERRORS(cudaMalloc(
//        &d_conv2,
//        sizeof(float) * context.m_batchSize * conv2.out_channels * conv2.out_height *
//            conv2.out_width));
//    CHECK_CUDA_ERRORS(cudaMalloc(
//        &d_pool2,
//        sizeof(float) * context.m_batchSize * conv2.out_channels *
//            (conv2.out_height / pool2.stride) * (conv2.out_width / pool2.stride)));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_fc1, sizeof(float) * context.m_batchSize * fc1.outputs));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_fc1relu, sizeof(float) * context.m_batchSize * fc1.outputs));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_fc2, sizeof(float) * context.m_batchSize * fc2.outputs));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_fc2smax, sizeof(float) * context.m_batchSize * fc2.outputs));
//
//    // Network parameters
//    float *d_pconv1, *d_pconv1bias, *d_pconv2, *d_pconv2bias;
//    float *d_pfc1, *d_pfc1bias, *d_pfc2, *d_pfc2bias;
//
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_pconv1, sizeof(float) * conv1.pconv.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_pconv1bias, sizeof(float) * conv1.pbias.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_pconv2, sizeof(float) * conv2.pconv.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_pconv2bias, sizeof(float) * conv2.pbias.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_pfc1, sizeof(float) * fc1.pneurons.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_pfc1bias, sizeof(float) * fc1.pbias.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_pfc2, sizeof(float) * fc2.pneurons.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_pfc2bias, sizeof(float) * fc2.pbias.size()));
//
//    // Network parameter gradients
//    float *d_gconv1, *d_gconv1bias, *d_gconv2, *d_gconv2bias;
//    float *d_gfc1, *d_gfc1bias, *d_gfc2, *d_gfc2bias;
//
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_gconv1, sizeof(float) * conv1.pconv.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_gconv1bias, sizeof(float) * conv1.pbias.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_gconv2, sizeof(float) * conv2.pconv.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_gconv2bias, sizeof(float) * conv2.pbias.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_gfc1, sizeof(float) * fc1.pneurons.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_gfc1bias, sizeof(float) * fc1.pbias.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_gfc2, sizeof(float) * fc2.pneurons.size()));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_gfc2bias, sizeof(float) * fc2.pbias.size()));
//
//    // Differentials w.r.t. data
//    float *d_dpool1, *d_dpool2, *d_dconv2, *d_dfc1, *d_dfc1relu, *d_dfc2, *d_dfc2smax, *d_dlossdata;
//    //                         Buffer     | Element       | N                   | C | H | W
//    //-----------------------------------------------------------------------------------------------------------------------------------------
//    CHECK_CUDA_ERRORS(cudaMalloc(
//        &d_dpool1,
//        sizeof(float) * context.m_batchSize * conv1.out_channels * conv1.out_height *
//            conv1.out_width));
//    CHECK_CUDA_ERRORS(cudaMalloc(
//        &d_dpool2,
//        sizeof(float) * context.m_batchSize * conv2.out_channels * conv2.out_height *
//            conv2.out_width));
//    CHECK_CUDA_ERRORS(cudaMalloc(
//        &d_dconv2,
//        sizeof(float) * context.m_batchSize * conv1.out_channels *
//            (conv1.out_height / pool1.stride) * (conv1.out_width / pool1.stride)));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_dfc1, sizeof(float) * context.m_batchSize * fc1.inputs));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_dfc1relu, sizeof(float) * context.m_batchSize * fc1.outputs));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_dfc2, sizeof(float) * context.m_batchSize * fc2.inputs));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_dfc2smax, sizeof(float) * context.m_batchSize * fc2.outputs));
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_dlossdata, sizeof(float) * context.m_batchSize * fc2.outputs));
//
//    // Temporary buffers and workspaces
//    float *d_onevec;
//    void *d_cudnn_workspace = nullptr;
//    CHECK_CUDA_ERRORS(cudaMalloc(&d_onevec, sizeof(float) * context.m_batchSize));
//    if (context.m_workspaceSize > 0)
//        CHECK_CUDA_ERRORS(cudaMalloc(&d_cudnn_workspace, context.m_workspaceSize));
//
//    /////////////////////////////////////////////////////////////////////////////
//
//    // Copy initial network to device
//    CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//        d_pconv1, &conv1.pconv[0], sizeof(float) * conv1.pconv.size(), cudaMemcpyHostToDevice));
//    CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//        d_pconv1bias, &conv1.pbias[0], sizeof(float) * conv1.pbias.size(), cudaMemcpyHostToDevice));
//    CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//        d_pconv2, &conv2.pconv[0], sizeof(float) * conv2.pconv.size(), cudaMemcpyHostToDevice));
//    CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//        d_pconv2bias, &conv2.pbias[0], sizeof(float) * conv2.pbias.size(), cudaMemcpyHostToDevice));
//    CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//        d_pfc1, &fc1.pneurons[0], sizeof(float) * fc1.pneurons.size(), cudaMemcpyHostToDevice));
//    CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//        d_pfc1bias, &fc1.pbias[0], sizeof(float) * fc1.pbias.size(), cudaMemcpyHostToDevice));
//    CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//        d_pfc2, &fc2.pneurons[0], sizeof(float) * fc2.pneurons.size(), cudaMemcpyHostToDevice));
//    CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//        d_pfc2bias, &fc2.pbias[0], sizeof(float) * fc2.pbias.size(), cudaMemcpyHostToDevice));
//
//    // Fill one-vector with ones
//    FillOnes<<<RoundUp(context.m_batchSize, BW), BW>>>(d_onevec, context.m_batchSize);
//
//    printf("Preparing dataset\n");
//
//    // Normalize training set to be in [0,1]
//    std::vector<float> train_images_float(train_images.size()), train_labels_float(train_size);
//    for (size_t i = 0; i < train_size * channels * width * height; ++i)
//        train_images_float[i] = (float)train_images[i] / 255.0f;
//
//    for (size_t i = 0; i < train_size; ++i)
//        train_labels_float[i] = (float)train_labels[i];
//
//    printf("Training...\n");
//
//    // Use SGD to train the network
//    CHECK_CUDA_ERRORS(cudaDeviceSynchronize());
//    auto t1 = std::chrono::high_resolution_clock::now();
//    for (int iter = 0; iter < FLAGS_iterations; ++iter) {
//        // Train
//        int imageid = iter % (train_size / context.m_batchSize);
//
//        // Prepare current batch on device
//        CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//            d_data,
//            &train_images_float[imageid * context.m_batchSize * width * height * channels],
//            sizeof(float) * context.m_batchSize * channels * width * height,
//            cudaMemcpyHostToDevice));
//        CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//            d_labels,
//            &train_labels_float[imageid * context.m_batchSize],
//            sizeof(float) * context.m_batchSize,
//            cudaMemcpyHostToDevice));
//
//        // Forward propagation
//        context.ForwardPropagation(
//            d_data,
//            d_conv1,
//            d_pool1,
//            d_conv2,
//            d_pool2,
//            d_fc1,
//            d_fc1relu,
//            d_fc2,
//            d_fc2smax,
//            d_pconv1,
//            d_pconv1bias,
//            d_pconv2,
//            d_pconv2bias,
//            d_pfc1,
//            d_pfc1bias,
//            d_pfc2,
//            d_pfc2bias,
//            d_cudnn_workspace,
//            d_onevec);
//
//        // Backward propagation
//        context.Backpropagation(
//            conv1,
//            pool1,
//            conv2,
//            pool2,
//            d_data,
//            d_labels,
//            d_conv1,
//            d_pool1,
//            d_conv2,
//            d_pool2,
//            d_fc1,
//            d_fc1relu,
//            d_fc2,
//            d_fc2smax,
//            d_dlossdata,
//            d_pconv1,
//            d_pconv1bias,
//            d_pconv2,
//            d_pconv2bias,
//            d_pfc1,
//            d_pfc1bias,
//            d_pfc2,
//            d_pfc2bias,
//            d_gconv1,
//            d_gconv1bias,
//            d_dpool1,
//            d_gconv2,
//            d_gconv2bias,
//            d_dconv2,
//            d_dpool2,
//            d_gfc1,
//            d_gfc1bias,
//            d_dfc1,
//            d_dfc1relu,
//            d_gfc2,
//            d_gfc2bias,
//            d_dfc2,
//            d_cudnn_workspace,
//            d_onevec);
//
//        // Compute learning rate
//        float learningRate = static_cast<float>(
//            FLAGS_learning_rate * pow((1.0 + FLAGS_lr_gamma * iter), (-FLAGS_lr_power)));
//
//        // Update weights
//        context.UpdateWeights(
//            learningRate,
//            conv1,
//            conv2,
//            d_pconv1,
//            d_pconv1bias,
//            d_pconv2,
//            d_pconv2bias,
//            d_pfc1,
//            d_pfc1bias,
//            d_pfc2,
//            d_pfc2bias,
//            d_gconv1,
//            d_gconv1bias,
//            d_gconv2,
//            d_gconv2bias,
//            d_gfc1,
//            d_gfc1bias,
//            d_gfc2,
//            d_gfc2bias);
//    }
//    CHECK_CUDA_ERRORS(cudaDeviceSynchronize());
//    auto t2 = std::chrono::high_resolution_clock::now();
//
//    printf(
//        "Iteration time: %f ms\n",
//        std::chrono::duration_cast<std::chrono::microseconds>(t2 - t1).count() / 1000.0f /
//            FLAGS_iterations);
//
//    // if (FLAGS_save_data) {
//    //     // Copy trained weights from GPU to CPU
//    //     CHECK_CUDA_ERRORS(cudaMemcpy(
//    //         &conv1.pconv[0], d_pconv1, sizeof(float) * conv1.pconv.size(),
//    //         cudaMemcpyDeviceToHost));
//    //     CHECK_CUDA_ERRORS(cudaMemcpy(
//    //         &conv1.pbias[0],
//    //         d_pconv1bias,
//    //         sizeof(float) * conv1.pbias.size(),
//    //         cudaMemcpyDeviceToHost));
//    //     CHECK_CUDA_ERRORS(cudaMemcpy(
//    //         &conv2.pconv[0], d_pconv2, sizeof(float) * conv2.pconv.size(),
//    //         cudaMemcpyDeviceToHost));
//    //     CHECK_CUDA_ERRORS(cudaMemcpy(
//    //         &conv2.pbias[0],
//    //         d_pconv2bias,
//    //         sizeof(float) * conv2.pbias.size(),
//    //         cudaMemcpyDeviceToHost));
//    //     CHECK_CUDA_ERRORS(cudaMemcpy(
//    //         &fc1.pneurons[0], d_pfc1, sizeof(float) * fc1.pneurons.size(),
//    //         cudaMemcpyDeviceToHost));
//    //     CHECK_CUDA_ERRORS(cudaMemcpy(
//    //         &fc1.pbias[0], d_pfc1bias, sizeof(float) * fc1.pbias.size(),
//    //         cudaMemcpyDeviceToHost));
//    //     CHECK_CUDA_ERRORS(cudaMemcpy(
//    //         &fc2.pneurons[0], d_pfc2, sizeof(float) * fc2.pneurons.size(),
//    //         cudaMemcpyDeviceToHost));
//    //     CHECK_CUDA_ERRORS(cudaMemcpy(
//    //         &fc2.pbias[0], d_pfc2bias, sizeof(float) * fc2.pbias.size(),
//    //         cudaMemcpyDeviceToHost));
//
//    //     // Now save data
//    //     printf("Saving data to file\n");
//    //     conv1.ToFile("conv1");
//    //     conv2.ToFile("conv2");
//    //     fc1.ToFile("ip1");
//    //     fc2.ToFile("ip2");
//    // }
//
//    float classification_error = 1.0f;
//
//    int classifications = FLAGS_classify;
//    if (classifications < 0)
//        classifications = (int)test_size;
//
//    // Test the resulting neural network's classification
//    if (classifications > 0) {
//        // Initialize a TrainingContext structure for testing (different batch size)
//        TrainingContext test_context(FLAGS_gpu, 1, conv1, pool1, conv2, pool2, fc1, fc2);
//
//        // Ensure correct workspaceSize is allocated for testing
//        if (context.m_workspaceSize < test_context.m_workspaceSize) {
//            CHECK_CUDA_ERRORS(cudaFree(d_cudnn_workspace));
//            CHECK_CUDA_ERRORS(cudaMalloc(&d_cudnn_workspace, test_context.m_workspaceSize));
//        }
//
//        int num_errors = 0;
//        for (int i = 0; i < classifications; ++i) {
//            std::vector<float> data(width * height);
//            // Normalize image to be in [0,1]
//            for (int j = 0; j < width * height; ++j)
//                data[j] = (float)test_images[i * width * height * channels + j] / 255.0f;
//
//            CHECK_CUDA_ERRORS(cudaMemcpyAsync(
//                d_data, &data[0], sizeof(float) * width * height, cudaMemcpyHostToDevice));
//
//            // Forward propagate test image
//            test_context.ForwardPropagation(
//                d_data,
//                d_conv1,
//                d_pool1,
//                d_conv2,
//                d_pool2,
//                d_fc1,
//                d_fc1relu,
//                d_fc2,
//                d_fc2smax,
//                d_pconv1,
//                d_pconv1bias,
//                d_pconv2,
//                d_pconv2bias,
//                d_pfc1,
//                d_pfc1bias,
//                d_pfc2,
//                d_pfc2bias,
//                d_cudnn_workspace,
//                d_onevec);
//
//            // Perform classification
//            std::vector<float> class_vec(10);
//
//            // Copy back result
//            CHECK_CUDA_ERRORS(
//                cudaMemcpy(&class_vec[0], d_fc2smax, sizeof(float) * 10, cudaMemcpyDeviceToHost));
//
//            // Determine classification according to maximal response
//            int chosen = 0;
//            for (int id = 1; id < 10; ++id) {
//                if (class_vec[chosen] < class_vec[id])
//                    chosen = id;
//            }
//
//            if (chosen != test_labels[i])
//                ++num_errors;
//        }
//        classification_error = (float)num_errors / (float)classifications;
//
//        printf(
//            "Classification result: %.2f%% error (used %d images)\n",
//            classification_error * 100.0f,
//            (int)classifications);
//    }
//
//    // Free data structures
//    CHECK_CUDA_ERRORS(cudaFree(d_data));
//    CHECK_CUDA_ERRORS(cudaFree(d_conv1));
//    CHECK_CUDA_ERRORS(cudaFree(d_pool1));
//    CHECK_CUDA_ERRORS(cudaFree(d_conv2));
//    CHECK_CUDA_ERRORS(cudaFree(d_pool2));
//    CHECK_CUDA_ERRORS(cudaFree(d_fc1));
//    CHECK_CUDA_ERRORS(cudaFree(d_fc2));
//    CHECK_CUDA_ERRORS(cudaFree(d_pconv1));
//    CHECK_CUDA_ERRORS(cudaFree(d_pconv1bias));
//    CHECK_CUDA_ERRORS(cudaFree(d_pconv2));
//    CHECK_CUDA_ERRORS(cudaFree(d_pconv2bias));
//    CHECK_CUDA_ERRORS(cudaFree(d_pfc1));
//    CHECK_CUDA_ERRORS(cudaFree(d_pfc1bias));
//    CHECK_CUDA_ERRORS(cudaFree(d_pfc2));
//    CHECK_CUDA_ERRORS(cudaFree(d_pfc2bias));
//    CHECK_CUDA_ERRORS(cudaFree(d_gconv1));
//    CHECK_CUDA_ERRORS(cudaFree(d_gconv1bias));
//    CHECK_CUDA_ERRORS(cudaFree(d_gconv2));
//    CHECK_CUDA_ERRORS(cudaFree(d_gconv2bias));
//    CHECK_CUDA_ERRORS(cudaFree(d_gfc1));
//    CHECK_CUDA_ERRORS(cudaFree(d_gfc1bias));
//    CHECK_CUDA_ERRORS(cudaFree(d_dfc1));
//    CHECK_CUDA_ERRORS(cudaFree(d_gfc2));
//    CHECK_CUDA_ERRORS(cudaFree(d_gfc2bias));
//    CHECK_CUDA_ERRORS(cudaFree(d_dfc2));
//    CHECK_CUDA_ERRORS(cudaFree(d_dpool1));
//    CHECK_CUDA_ERRORS(cudaFree(d_dconv2));
//    CHECK_CUDA_ERRORS(cudaFree(d_dpool2));
//    CHECK_CUDA_ERRORS(cudaFree(d_labels));
//    CHECK_CUDA_ERRORS(cudaFree(d_dlossdata));
//    CHECK_CUDA_ERRORS(cudaFree(d_onevec));
//    if (d_cudnn_workspace != nullptr)
//        CHECK_CUDA_ERRORS(cudaFree(d_cudnn_workspace));
//
//    return 0;
//}

int main() {

}