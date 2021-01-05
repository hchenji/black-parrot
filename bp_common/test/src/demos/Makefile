
include Makefile.frag

RISCV_GCC  = $(CROSS_COMPILE)gcc --static -nostartfiles -fPIC -march=rv64ima -mabi=lp64 -mcmodel=medany -I$(BP_TEST_DIR)/include
RISCV_LINK = -static -nostartfiles -L$(BP_TEST_DIR)/lib -lperch -T src/riscv.ld

.PHONY: all bp-demo-riscv bp-demo-s

all: bp-demo-s bp-demo-riscv

bp-demo-riscv: $(foreach x,$(subst -,_,$(BP_DEMOS)),$(x).riscv)
bp-demo-s    : $(foreach x,$(subst -,_,$(BP_DEMOS_C)),$(x).s)

%.riscv:
	$(RISCV_GCC) $(RISCV_LINK) -o $@ src/$*.s -lperch

bubblesort_mc_demo_%.s:
	$(RISCV_GCC) -DNUM_CORES=$(notdir $*) -S -o src/bubblesort_mc_demo_$(notdir $*).s src/bubblesort_mc_demo.c

%.s:
	$(RISCV_GCC) -S -o src/$@ src/$*.c
	
clean:
	rm -f *.riscv
	rm -f bubblesort_mc_demo_*.s


