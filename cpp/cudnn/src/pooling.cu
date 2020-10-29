//
// Created by Maksim Levental on 10/29/20.
//

#include <pooling.cuh>

Pooling::Pooling(
    std::string name, int kernel_size, int padding, int stride, cudnnPoolingMode_t mode)
    : kernel_size_(kernel_size), padding_(padding), stride_(stride), mode_(mode) {
    name_ = std::move(name);

    cudnnCreatePoolingDescriptor(&pool_desc_);
    cudnnSetPooling2dDescriptor(
        pool_desc_,
        mode_,
        CUDNN_PROPAGATE_NAN,
        kernel_size_,
        kernel_size_,
        padding_,
        padding_,
        stride_,
        stride_);
}

Pooling::~Pooling() { cudnnDestroyPoolingDescriptor(pool_desc_); }

void Pooling::fwd_initialize(Tensor<float> *input) {
    if (input_ == nullptr || batch_size_ != input->get_batch_size()) {
        input_ = input;

        // resource initialize
        input_desc_ = input_->tensor_descriptor();
        batch_size_ = input->get_batch_size();

        // setting output
        cudnnGetPooling2dForwardOutputDim(
            pool_desc_,
            input_desc_,
            &output_size_[0],
            &output_size_[1],
            &output_size_[2],
            &output_size_[3]);
        if (output_ == nullptr)
            output_ = new Tensor<float>(output_size_);
        else
            output_->reset(output_size_);

        output_desc_ = output_->tensor_descriptor();
    }
}

Tensor<float> *Pooling::forward(Tensor<float> *input) {
    cudnnPoolingForward(
        cuda_->cudnn(),
        pool_desc_,
        &cuda_->one,
        input_desc_,
        input_->get_device_ptr(),
        &cuda_->zero,
        output_desc_,
        output_->get_device_ptr());

    return output_;
}

Tensor<float> *Pooling::backward(Tensor<float> *grad_output) {
    checkCudnnErrors(cudnnPoolingBackward(
        cuda_->cudnn(),
        pool_desc_,
        &cuda_->one,
        output_desc_,
        output_->get_device_ptr(),
        output_desc_,
        grad_output->get_device_ptr(),
        input_desc_,
        input_->get_device_ptr(),
        &cuda_->zero,
        input_desc_,
        grad_input_->get_device_ptr()));

    return grad_input_;
}
