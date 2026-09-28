// tb_ps1_cache_conc with the cache in block-RAM mode (ps1_cache BRAM=1, FAST_ACK=1): see that file
`define TB_CACHE_BRAM
`include "../../sim/tb_ps1_cache_conc.v"
`undef TB_CACHE_BRAM
