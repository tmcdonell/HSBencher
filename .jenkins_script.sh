

git submodule update --init
cabal sandbox init
cabal install -ffusion --enable-tests http-conduit-1.9.6 ./ ./hgdata_mirror/ --force-reinstalls 