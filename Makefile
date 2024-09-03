PATH := $(PATH):/sbin:/usr/sbin
IUCODE_TOOL ?= iucode_tool
IUC_FLAGS := -v
IUC_FINAL_FLAGS := -vv

# CUTDATE RANGE:
#
# This filter selects what we consider to be old microcode which
# should still be shipped even if Intel dropped them.  Note that
# it is useless to ship microcodes for anything the distro doesn't
# really support anymore
#
# Watch out: check in the changelog, if this filter will add
# microcodes that look like they've been recalled, use
# IUC_OLDIES_EXCLUDE to avoid shipping the probably recalled
# microcode.  Refer to IUC_EXCLUDE for IUC_OLDIES_EXCLUDE syntax.
#
# Last manual check: up to 2008-01-01
IUC_OLDIES_SELECT  := "--date-before=2008-01-01"
IUC_OLDIES_EXCLUDE :=

# EXCLUDING MICROCODES:
#
# Always document reason.  See iucode_tool(8) for -s !<sig> syntax
# Recalls might require use of .fw overrides to retain old version,
# instead of exclusions.  Exclusions have the highest priority, and
# will remove microcode added by any other means, including override
# files (.fw files).
IUC_EXCLUDE :=

# 0x106c0: alpha hardware, seen in a very very old microcode data file
IUC_EXCLUDE += -s !0x106c0

# INCLUDING MICROCODES:
#
# This should be used to add a microcode from any of the regular
# microcode bundles, without the need for an override file.  See
# iucode_tool(8) for -s <sig> syntax.  Always document the reason,
# as per IUC_EXCLUDE.
IUC_INCLUDE :=

# Keep sorting order predictable or things will break
export LC_COLLATE=C

MICROCODE_REG_DBIN    := $(patsubst microcode-%.d/,microcode-%.dbin,$(wildcard microcode-*.d/))
MICROCODE_REG_SOURCES := $(sort $(wildcard microcode-*.dat microcode-*.bin) $(MICROCODE_REG_DBIN))
MICROCODE_SUP_SOURCES := $(wildcard supplementary-ucode-*.bin supplementary-ucode-*.d/)
MICROCODE_OVERRIDES   := $(wildcard *.fw)

MICROCODE_FINAL_REG_SOURCES :=
ifneq ($(IUC_OLDIES_SELECT),)
	MICROCODE_FINAL_REG_SOURCES += microcode-oldies.pbin
endif
ifneq ($(IUC_INCLUDE),)
	MICROCODE_FINAL_REG_SOURCES += microcode-includes.pbin
endif
MICROCODE_FINAL_REG_SOURCES += $(lastword $(MICROCODE_REG_SOURCES))

ifneq ($(MICROCODE_SUP_SOURCES),)
MICROCODE_FINAL_SOURCES := microcode-aux.pbin
else
MICROCODE_FINAL_SOURCES := $(MICROCODE_FINAL_REG_SOURCES)
endif
ifneq ($(MICROCODE_OVERRIDES),)
	MICROCODE_FINAL_SOURCES += microcode-overrides.pbin
endif

all: intel-microcode.bin intel-microcode-64.bin

# When processing a directory that contains a single upstream
# microcode release (split over many binary microcode files), we need
# to group it into a single (temporary) bundle for downgrade mode to
# work as expected.  Using iucode_tool (in the default --no-downgrade
# mode) to generate the temporary bundle ensures reproducibility,
# since it will sort out any conflicts in a predictable way.

microcode-%.dbin: microcode-%.d/
	@echo
	@echo Preprocessing microcode directory $^ into $@...
	@$(IUCODE_TOOL) $(IUC_FLAGS) --overwrite -w "$@" $^

# When looking for "old" microcodes that we should ship even if they
# are not in the latest regular microcode bundle anymore, we use a
# date filter to select *signatures* of microcodes that should be
# included (instead of directly selecting the microcode itself).
#
# Then, the "latest" microcode (in source file order, due to the use
# of downgrade mode) for each such signatures will be selected,
# regardless of the date on the microcode itself.

microcode-oldies.pbin: $(MICROCODE_REG_SOURCES)
	@echo
	@echo Preprocessing older regular microcode...
	@$(IUCODE_TOOL) $(IUC_FLAGS) \
		$(IUC_OLDIES_SELECT) $(IUC_OLDIES_EXCLUDE) \
		--loose-date-filtering --downgrade --overwrite -w "$@" $^

microcode-includes.pbin: $(MICROCODE_REG_SOURCES)
	@echo
	@echo Preprocessing force-included regular microcode...
	@$(IUCODE_TOOL) $(IUC_FLAGS) -s! $(IUC_INCLUDE) \
		--downgrade --overwrite -w "$@" $^

# When there are supplementary microcode bundles, they must be merged
# with the regular microcode in a separate step, since all such
# microcodes must have the same precedence.  We use two intermediate
# bundles for this.
#
# The oldies and force-included microcodes are bundled together with
# the latest regular microcode bundle in microcode-regular.pbin.  The
# precedence order for downgrading is:
#
#     oldies < includes < latest regular microcode bundle
#
# The precedence order won't matter for oldies and includes, as they
# either have different microcode, or microcode with the same
# revision.
#
# Then, microcode-regular.pbin is merged with all supplementary
# microcode bundles, with the downgrade logic disabled in the
# microcode-aux.pbin target.  The result will be used by the final
# target.
#
# When there are no supplementary microcode updates, we can do all the
# merging with the downgrade logic active in a single go in the final
# target.

microcode-regular.pbin: $(MICROCODE_FINAL_REG_SOURCES)
	@echo
	@echo Building microcode bundle for regular microcode...
	@$(IUCODE_TOOL) $(IUC_FINAL_FLAGS) --downgrade --overwrite -w "$@" $^

microcode-aux.pbin: microcode-regular.pbin $(MICROCODE_SUP_SOURCES)
	@echo
	@echo Merging regular and supplementary microcode bundles...
	@$(IUCODE_TOOL) $(IUC_FINAL_FLAGS) --overwrite -w "$@" $^

# The microcode overrides are bundled together to sort out any
# duplication and revision level issues.
microcode-overrides.pbin: $(MICROCODE_OVERRIDES)
	@echo
	@echo Preprocessing microcode overrides...
	@$(IUCODE_TOOL) $(IUC_FLAGS) --overwrite -w "$@" $^

# Final target
intel-microcode.bin: $(MICROCODE_FINAL_SOURCES)
	@echo
	@echo Building final microcode bundle...
	@$(IUCODE_TOOL) $(IUC_FINAL_FLAGS) $(IUC_EXCLUDE) \
		--downgrade --overwrite -w "$@" $^

intel-microcode-64.bin: intel-microcode.bin
	@echo
	@echo Building stripped-down microcode bundle for x86-64 and x32...
	@$(IUCODE_TOOL) $(IUC_FLAGS) \
		$(shell sed -n -r -e '/^i.86/ { s/^[^ ]+ +/-s !/;s/ +\#.*//;p}' cpu-signatures.txt) $(IUC_EXCLUDE) \
		--overwrite -w "$@" $^

distclean: clean
clean:
	rm -f intel-microcode-64.bin intel-microcode.bin
	rm -f microcode-overrides.pbin microcode-oldies.pbin microcode-includes.pbin microcode-regular.pbin microcode-aux.pbin
	rm -f microcode-*.dbin

.PHONY: clean
