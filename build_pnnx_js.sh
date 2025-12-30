#!/bin/bash
set -e  # 遇到错误立即停止

# =================配置区域=================
WORK_DIR=$(pwd)
INSTALL_DIR="$HOME/wasm_deps"
CPU_CORES=$(nproc)

echo ">>> 工作目录: $WORK_DIR"
echo ">>> 安装目录: $INSTALL_DIR"
echo ">>> 使用核心数: $CPU_CORES"

# 全局体积优化标志 (Wasm64 + 体积优化 + LTO)
# -Oz: 激进的体积优化
# -flto: 链接时优化
# -g0: 移除调试信息
OPT_FLAGS="-s MEMORY64=1 -D_LARGEFILE64_SOURCE -Oz -flto -g0"

# 创建安装目录
mkdir -p "$INSTALL_DIR"

# ================= 1. Emscripten 环境 =================
echo ">>> [1/5] 设置 Emscripten..."
if [ ! -d "emsdk" ]; then
    git clone https://github.com/emscripten-core/emsdk.git
    cd emsdk
    ./emsdk install latest
    ./emsdk activate latest
fi
cd "$WORK_DIR/emsdk"
source ./emsdk_env.sh
cd "$WORK_DIR"

export CFLAGS="$OPT_FLAGS"
export CXXFLAGS="$OPT_FLAGS"
export LDFLAGS="$OPT_FLAGS"

# ================= 2. PyTorch (Host Protoc & Wasm Libs) =================
echo ">>> [2/5] 准备 PyTorch..."
if [ ! -d "pytorch_wasm" ]; then
    git clone https://github.com/futz12/pytorch_wasm pytorch_wasm
    cd pytorch_wasm
    git submodule sync && git submodule update --init --recursive
    cd "$WORK_DIR"
fi

# --- 2.1 编译 Host Protoc (本机工具) ---
echo ">>> [2.1] 编译 Host Protoc..."
cd pytorch_wasm
cmake -Bbuild_host \
    -DBUILD_CUSTOM_PROTOBUF=ON \
    -DPROTOBUF_PROTOC_EXECUTABLE="" \
    -DCAFFE2_CUSTOM_PROTOC_EXECUTABLE=""
# Host 工具使用 Release 保证编译速度
cmake --build build_host --config Release -j$CPU_CORES --target protoc

HOST_PROTOC_PATH="$(pwd)/build_host/bin/protoc"
if [ ! -f "$HOST_PROTOC_PATH" ]; then
    HOST_PROTOC_PATH=$(find "$(pwd)/build_host" -name protoc -type f | head -n 1)
fi
echo ">>> 使用 Host Protoc: $HOST_PROTOC_PATH"

# --- 2.2 编译 PyTorch Wasm 库 (MinSizeRel) ---
echo ">>> [2.2] 编译 PyTorch Wasm 库..."
emcmake cmake -Bbuild_wasm \
    -DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_C_FLAGS="$OPT_FLAGS" \
    -DCMAKE_CXX_FLAGS="$OPT_FLAGS" \
    -DUSE_KINETO=OFF -DUSE_CUDA=OFF -DUSE_MPI=OFF -DUSE_OPENMP=OFF -DUSE_MKLDNN=OFF \
    -DUSE_QNNPACK=OFF -DUSE_PYTORCH_QNNPACK=OFF -DUSE_XNNPACK=OFF \
    -DUSE_NNPACK=OFF -DUSE_DISTRIBUTED=OFF -DUSE_FBGEMM=OFF -DUSE_FAKELOWP=OFF \
    -DBUILD_TEST=OFF -DBUILD_BINARY=OFF -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_CUSTOM_PROTOBUF=ON \
    -DCAFFE2_CUSTOM_PROTOC_EXECUTABLE="$HOST_PROTOC_PATH" \
    -DPROTOBUF_PROTOC_EXECUTABLE="$HOST_PROTOC_PATH" \
    -DONNX_CUSTOM_PROTOC_EXECUTABLE="$HOST_PROTOC_PATH"

cd build_wasm
emmake make install -j$CPU_CORES
cd "$WORK_DIR"

# ================= 3. ONNX Runtime (Master分支 & 极简版) =================
echo ">>> [3/5] 编译 ONNX Runtime (Master Minimal - MinSizeRel)..."
if [ ! -d "onnxruntime" ]; then
    echo "正在 Clone ORT Master 分支..."
    git clone --recursive https://github.com/microsoft/onnxruntime.git
fi
cd onnxruntime

mkdir -p build_wasm && cd build_wasm

emcmake cmake ../cmake \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_SYSTEM_PROCESSOR=wasm64 \
    -DCMAKE_FIND_ROOT_PATH="$INSTALL_DIR" \
    -Donnxruntime_BUILD_UNIT_TESTS=OFF \
    -Donnxruntime_ENABLE_PYTHON=OFF \
    -Donnxruntime_BUILD_SHARED_LIB=OFF \
    -Donnxruntime_USE_PREINSTALLED_PROTOBUF=ON \
    -DProtobuf_INCLUDE_DIR="$INSTALL_DIR/include" \
    -DProtobuf_LIBRARY="$INSTALL_DIR/lib/libprotobuf.a" \
    -DProtobuf_PROTOC_EXECUTABLE="$HOST_PROTOC_PATH" \
    -DONNX_CUSTOM_PROTOC_EXECUTABLE="$HOST_PROTOC_PATH" \
    -Donnxruntime_DISABLE_CONTRIB_OPS=ON \
    -Donnxruntime_DISABLE_ML_OPS=ON \
    -Donnxruntime_USE_EXTENSIONS=OFF \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DCMAKE_C_FLAGS="$OPT_FLAGS -DORT_WASM64" \
    -DCMAKE_CXX_FLAGS="$OPT_FLAGS -DORT_WASM64"

echo ">>> 编译 ORT 核心库..."
emmake make install -j$CPU_CORES

cp _deps/onnx-build/*.a $INSTALL_DIR/lib
find _deps/abseil_cpp-build/absl -name "libabsl_*.a" -exec cp {} "$INSTALL_DIR/lib/" \;
cp _deps/re2-build/*.a $INSTALL_DIR/lib

cd "$WORK_DIR"

# ================= 4. Torchvision (Wasm64 - MinSizeRel) =================
echo ">>> [4/5] 编译 Torchvision (No Image)..."
if [ ! -d "torchvision" ]; then
    git clone https://github.com/pytorch/vision
    cd vision
    mkdir -p build_wasm && cd build_wasm
    
    emcmake cmake .. \
        -DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_FIND_ROOT_PATH="$INSTALL_DIR" \
        -DTorch_DIR="$INSTALL_DIR/share/cmake/Torch" \
        -DTORCH_LIBRARY="$INSTALL_DIR/lib/libtorch.a" \
        -DTORCH_INCLUDE_DIRECTORIES="$INSTALL_DIR/include" \
        -DCMAKE_CXX_FLAGS="-I$INSTALL_DIR/include/torch/csrc/api/include -I$INSTALL_DIR/include $OPT_FLAGS" \
        -DCMAKE_C_FLAGS="$OPT_FLAGS" \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_CUDA=OFF -DWITH_IMAGE=OFF -DWITH_PNG=OFF -DWITH_JPEG=OFF \
        -DBUILD_PYTHON=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TEST=OFF
        
    emmake make install -j$CPU_CORES
    cd "$WORK_DIR"
fi

# ================= 5. PNNX (Wasm64 - 最终链接) =================
echo ">>> [5/5] 编译 PNNX..."
if [ -z "$HOST_PROTOC_PATH" ]; then
     HOST_PROTOC_PATH="$WORK_DIR/pytorch_wasm/build_host/bin/protoc"
fi

if [ ! -d "ncnn" ]; then
    git clone https://github.com/tencent/ncnn
fi

cd ncnn/tools/pnnx
mkdir -p build && cd build

echo ">>> 配置 CMake..."
ORT_INC_DIR="$INSTALL_DIR/include/onnxruntime"
ABSL_LIBS=$(ls "$INSTALL_DIR/lib"/libabsl_*.a | tr '\n' ' ')
ONNX_LIBS=$(ls "$INSTALL_DIR/lib"/libonnx*.a | tr '\n' ' ')

emcmake cmake .. \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
    -DCMAKE_FIND_ROOT_PATH="$INSTALL_DIR" \
    -DTorch_DIR="$INSTALL_DIR/share/cmake/Torch" \
    -DCMAKE_DISABLE_FIND_PACKAGE_TorchVision=TRUE \
    -DTorchVision_INSTALL_DIR="$INSTALL_DIR" \
    -Donnxruntime_INSTALL_DIR="$INSTALL_DIR" \
    -Donnxruntime_INCLUDE_DIR="$ORT_INC_DIR" \
    -DCAFFE2_CUSTOM_PROTOC_EXECUTABLE="$HOST_PROTOC_PATH" \
    -DPROTOBUF_PROTOC_EXECUTABLE="$HOST_PROTOC_PATH" \
    -DONNX_CUSTOM_PROTOC_EXECUTABLE="$HOST_PROTOC_PATH" \
    -DCMAKE_C_FLAGS="$OPT_FLAGS" \
    -DCMAKE_CXX_FLAGS="$OPT_FLAGS -I$INSTALL_DIR/include/torch/csrc/api/include -I$INSTALL_DIR/include -I$ORT_INC_DIR" \
    -DCMAKE_EXE_LINKER_FLAGS="\
        $OPT_FLAGS \
        -s ALLOW_MEMORY_GROWTH=1 \
        -s MAXIMUM_MEMORY=16GB \
        -s FORCE_FILESYSTEM=1 \
        -s MODULARIZE=1 \
        -s EXPORT_NAME='createPnnxModule' \
        -s EXPORTED_RUNTIME_METHODS=['callMain','FS'] \
        -s ENVIRONMENT='web,worker' \
        -s DISABLE_EXCEPTION_CATCHING=1 \
        -s MALLOC='emmalloc' \
        --closure 1 \
        -s STACK_SIZE=52428800 \
        -s INITIAL_MEMORY=134217728 \
        -L$INSTALL_DIR/lib \
        -Wl,--start-group \
        ${ONNX_LIBS} \
        -lprotobuf \
        -lre2 \
        ${ABSL_LIBS} \
        -Wl,--end-group \
    "

echo ">>> 开始编译 PNNX..."
emmake make -j$CPU_CORES

# ================= 6. 复制产物 =================
echo ">>> [6/6] 正在将文件复制到根目录: $WORK_DIR ..."
cp src/pnnx.wasm "$WORK_DIR/pnnx.wasm"
cp src/pnnx.js "$WORK_DIR/pnnx.js"

echo ">>> 全部完成！"
echo "最终文件："
ls -lh "$WORK_DIR/pnnx.wasm" "$WORK_DIR/pnnx.js"