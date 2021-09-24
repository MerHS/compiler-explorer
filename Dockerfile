FROM        ubuntu:20.04

ENV TZ=Asia/Seoul
RUN apt-get -y update \
  && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# install common build packages
WORKDIR /root
RUN apt-get -y install build-essential git-all wget curl vim software-properties-common m4

# install python/pip
RUN add-apt-repository ppa:deadsnakes/ppa  \
  && apt-get -y install python3.9 \
  && update-alternatives --install /usr/bin/python python /usr/bin/python3.9 3 \
  && apt-get -y install python3-distutils \
  && curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py \
  && python get-pip.py \
  && rm get-pip.py \
  && python -m pip install toml

# install cmake
RUN mkdir -p /root/lib/cmake \
  && wget https://github.com/Kitware/CMake/releases/download/v3.21.3/cmake-3.21.3-linux-x86_64.sh \
  && bash ./cmake-3.21.3-linux-x86_64.sh --skip-license --prefix=/root/lib/cmake \
  && rm cmake-3.21.3-linux-x86_64.sh
ENV PATH "$PATH:/root/lib/cmake/bin"

# install ninja-build
RUN apt-get -y install ninja-build

# install clang/llvm
RUN wget https://apt.llvm.org/llvm.sh \
  && bash llvm.sh 13 \
  && rm llvm.sh

ENV PATH "$PATH:/usr/lib/llvm-13/bin"

# install node
ENV NVM_DIR /root/.nvm
ENV NODE_VERSION 12.22.6

RUN curl https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash \
  && . $NVM_DIR/nvm.sh \
  && nvm install $NODE_VERSION \
  && nvm alias default $NODE_VERSION \
  && nvm use default

ENV NODE_PATH $NVM_DIR/v$NODE_VERSION/lib/node_modules
ENV PATH      $NVM_DIR/v$NODE_VERSION/bin:$PATH

# install jvm
RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0xB1998361219BD9C9 \
  && curl -O https://cdn.azul.com/zulu/bin/zulu-repo_1.0.0-2_all.deb \
  && apt-get -y install ./zulu-repo_1.0.0-2_all.deb \
  && apt-get update \
  && apt-get -y install zulu11-jdk \
  && rm ./zulu-repo_1.0.0-2_all.deb

# clone dependencies
RUN git clone --depth=1 https://github.com/llvm/llvm-project.git \
  && git clone --depth=1 https://github.com/Z3Prover/z3 \
  && git clone --depth=1 https://github.com/cvc5/cvc5 \
  && git clone https://github.com/aqjune/mlir-tv \
  && git clone https://github.com/MerHS/compiler-explorer \
  && mkdir -p /root/lib/llvm \
  && mkdir -p /root/lib/z3 \
  && mkdir -p /root/lib/cvc5 \
  && mkdir -p /root/mlir-tv/build \
  && mkdir -p /root/llvm-project/build  \
  && mkdir -p /root/z3/build \
  && mkdir -p /root/cvc5/build

# build llvm
WORKDIR /root/llvm-project/build
RUN cmake -G Ninja ../llvm \
  -DLLVM_ENABLE_PROJECTS='clang;libcxx;libcxxabi;mlir' \
  -DLLVM_BUILD_EXAMPLES=ON \
  -DLLVM_TARGETS_TO_BUILD="X86;NVPTX;AMDGPU" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DCMAKE_INSTALL_PREFIX=/root/lib/llvm \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DLLVM_ENABLE_LLD=ON
RUN cmake --build .
RUN cmake --build . --target install

# build z3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 3
WORKDIR /root/z3
RUN CXX=clang++ CC=clang python scripts/mk_make.py --prefix=/root/lib/z3
WORKDIR /root/z3/build
RUN make -j8 && make install

# build cvc5
WORKDIR /root/cvc5
RUN bash ./configure.sh --prefix=/root/lib/cvc5 --auto-download
WORKDIR /root/cvc5/build
RUN make -j8 && make check && make install

# clean repositories
RUN rm -rf /root/llvm-project /root/cvc5 /root/z3

# build mlir-tv
WORKDIR /root/mlir-tv/build
RUN cmake -DMLIR_DIR=/root/lib/llvm \
  -DZ3_DIR=/root/lib/z3 \
  -DCVC5_DIR=/root/lib/cvc5 \
  -DCMAKE_BUILD_TYPE=RELEASE \
  ..
RUN cmake --build .

# run compiler explorer
WORKDIR /root/compiler-explorer
EXPOSE 10240
CMD make EXTRA_ARGS="--language mlir-tv"
