FROM        ubuntu:20.04
MAINTAINER  mersshs@gmail.com
RUN         apt-get -y update

# install common build packages
WORKDIR /root
RUN apt-get -y install build-essential git-all wget curl vim software-properties-common

# install python/pip
RUN add-apt-repository ppa:deadsnakes/ppa
RUN apt-get install python3.9
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.9 3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 3
RUN curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
RUN python get-pip.py
RUN rm get-pip.py
RUN python -m pip install toml

# install cmake/ninja-build
RUN wget https://github.com/Kitware/CMake/releases/download/v3.21.3/cmake-3.21.3-linux-x86_64.sh
RUN bash ./cmake-3.21.3-linux-x86_64.sh
RUN rm cmake-3.21.3-linux-x86_64.sh
RUN mv cmake-3.21.3-linux-x86_64 cmake

ENV PATH "$PATH:/root/cmake/bin"
RUN apt-get install ninja-build

# install clang/llvm
RUN wget https://apt.llvm.org/llvm.sh
RUN bash llvm.sh 13
RUN rm llvm.sh
ENV PATH "$PATH:/usr/lib/llvm-13"

# install node
RUN apt-get -y install nodejs
RUN wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash
RUN source ~/.bashrc
RUN nvm install lts/erbium

# install jvm
RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0xB1998361219BD9C9
RUN curl -O https://cdn.azul.com/zulu/bin/zulu-repo_1.0.0-2_all.deb
RUN apt-get -y install ./zulu-repo_1.0.0-2_all.deb
RUN apt-get update
RUN apt-get -y install zulu11-jdk
RUN rm ./zulu-repo_1.0.0-2_all.deb

# clone dependencies
RUN git clone --depth=1 https://github.com/llvm/llvm-project.git
RUN git clone --depth=1 https://github.com/Z3Prover/z3
RUN git clone --depth=1 https://github.com/cvc5/cvc5
RUN git clone https://github.com/aqjune/mlir-tv
RUN git clone https://github.com/MerHS/compiler-explorer
RUN mkdir -p /root/lib/llvm
RUN mkdir -p /root/lib/z3
RUN mkdir -p /root/lib/cvc5
RUN mkdir -p /root/mlir-tv/build

# build llvm
RUN mkdir -p /root/llvm-project/build
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

WORKDIR /root
RUN rm -rf llvm-project

# build z3
RUN mkdir -p /root/z3/build
WORKDIR /root/z3
RUN CXX=clang++ CC=clang python scripts/mk_make.py --prefix=/root/lib/z3
WORKDIR /root/z3/build
RUN make -j8
RUN make install

WORKDIR /root
RUN rm -rf z3

# build cvc5
RUN mkdir -p /root/cvc5/build
WORKDIR /root/cvc5
RUN bash ./configure.sh --prefix=/root/lib/cvc5 --auto-download
WORKDIR /root/cvc5/build
RUN make -j8
RUN make check
RUN make install

WORKDIR /root
RUN rm -rf cvc5

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
