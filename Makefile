# -------------------------------------
#  This make file is for compiling the 
#  xup.asm
#
#  Use:
#    clean      - clean environment
#    all        - build all outputs
#    bin        - build binary output DOS .COM file format
#
#    all output builds will create a listing file
#
# -------------------------------------

#
# change log
# -------------------
# 07/12/2013        created
#

INCDIR = ~/Documents/bios/src/
BINDIR = .
DEBUG  =

DEPENDENCIES = xup.asm $(INCDIR)/iodef.asm

all : bin

bin : xup.com

xup.com : $(DEPENDENCIES)
	nasm $(DEBUG) -i $(INCDIR) -fbin xup.asm -o $(BINDIR)/xup.com -l $(BINDIR)/xup.lst

.PHONY : CLEAN
clean :
	rm -f $(BINDIR)/*com
	rm -f $(BINDIR)/*lst

