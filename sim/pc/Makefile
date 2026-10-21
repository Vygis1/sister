# sim/pc - pc_top under Verilator (WSL): make; ./obj_dir/Vpc_top <disk.img> boot0.rom boot1.rom [frames] [save_every] [cue]
R = ../../rtl
P = $(R)/pc
SRC = $(R)/pc_top.v $(R)/pc_ddr64.v $(R)/pc_disk.v $(R)/pc_fb.v $(R)/pc_cdda.v $(R)/mem_arb.v $(addprefix $(P)/,$(shell cat $(P)/files.f))
FLAGS = +1800-2017ext+sv --top-module pc_top --cc --exe --build -j 0 -O2 --threads $(THREADS) \
        -Wno-fatal -Wno-WIDTH -Wno-PINMISSING -Wno-COMBDLY -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
        -I$(P)/ao486 -CFLAGS "-O2 -std=c++17"
# CLK: the clock the core is built for (make CLK=62500000 OBJ=obj_62: the 62.5 MHz PC)
CLK ?= 50000000
OBJ ?= obj_dir
# THREADS: Verilator's simulation threads (1: as before). Note: with more than one the pc_top model is NOT
# deterministic (two runs of one binary differ within 4 M clocks) -- never use it for the trace-hash gate
THREADS ?= 1
# CHK: extra C++ defines for main.cpp (e.g. CHK=-DRGN_CHECK: check the CPU's avm_rgn against avm_address every clock)
CHK ?=
FLAGS += $(if $(CHK),-CFLAGS "$(CHK)",)
FLAGS += -GCLK_HZ=$(CLK) +define+CONSOLE_CLK_HZ=$(CLK) --Mdir $(OBJ) -CFLAGS "-DSIM_CLK_HZ=$(CLK)"
$(OBJ)/Vpc_top: $(SRC) main.cpp trace.vlt
	verilator $(FLAGS) trace.vlt $(SRC) main.cpp > $(OBJ).log 2>&1 || (grep -E "%Error" $(OBJ).log | head -20; false)
clean:
	rm -rf obj_dir
