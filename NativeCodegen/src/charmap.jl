# Pure-Julia port of Julia's identifier-character classification
# (src/flisp/julia_extensions.c: jl_id_start_char / jl_id_char), built on
# UnicodeNext's pure-Julia utf8proc port. Used by overlay methods so that
# compiled wasm needs no host-side unicode support. Validated exhaustively
# against the native C implementation over all codepoints in the test suite.

using UnicodeNext: UnicodeNext

const _CAT_LU = Int32(UnicodeNext.CATEGORY_LU)
const _CAT_LL = Int32(UnicodeNext.CATEGORY_LL)
const _CAT_LT = Int32(UnicodeNext.CATEGORY_LT)
const _CAT_LM = Int32(UnicodeNext.CATEGORY_LM)
const _CAT_LO = Int32(UnicodeNext.CATEGORY_LO)
const _CAT_MN = Int32(UnicodeNext.CATEGORY_MN)
const _CAT_MC = Int32(UnicodeNext.CATEGORY_MC)
const _CAT_ME = Int32(UnicodeNext.CATEGORY_ME)
const _CAT_ND = Int32(UnicodeNext.CATEGORY_ND)
const _CAT_NL = Int32(UnicodeNext.CATEGORY_NL)
const _CAT_NO = Int32(UnicodeNext.CATEGORY_NO)
const _CAT_PC = Int32(UnicodeNext.CATEGORY_PC)
const _CAT_SC = Int32(UnicodeNext.CATEGORY_SC)
const _CAT_SK = Int32(UnicodeNext.CATEGORY_SK)
const _CAT_SO = Int32(UnicodeNext.CATEGORY_SO)

function _is_wc_cat_id_start(wc::UInt32, cat::Int32)
    return (cat == _CAT_LU || cat == _CAT_LL || cat == _CAT_LT ||
            cat == _CAT_LM || cat == _CAT_LO || cat == _CAT_NL ||
            cat == _CAT_SC ||  # allow currency symbols
            # other symbols, but not arrows or replacement characters
            (cat == _CAT_SO && !(wc >= 0x2190 && wc <= 0x21FF) &&
             wc != 0xfffc && wc != 0xfffd &&
             wc != 0x233f &&   # notslash
             wc != 0x00a6) ||  # broken bar

            # math symbol (category Sm) allowlist
            (wc >= 0x2140 && wc <= 0x2a1c &&
             ((wc >= 0x2140 && wc <= 0x2144) ||  # ⅀, ⅁, ⅂, ⅃, ⅄
              wc == 0x223f || wc == 0x22be || wc == 0x22bf ||  # ∿, ⊾, ⊿
              wc == 0x22a4 || wc == 0x22a5 ||                  # ⊤ ⊥
              (wc >= 0x2200 && wc <= 0x2233 &&
               (wc == 0x2202 || wc == 0x2205 || wc == 0x2206 ||  # ∂, ∅, ∆
                wc == 0x2207 || wc == 0x220e || wc == 0x220f ||  # ∇, ∎, ∏
                wc == 0x2200 || wc == 0x2203 || wc == 0x2204 ||  # ∀, ∃, ∄
                wc == 0x2210 || wc == 0x2211 ||                  # ∐, ∑
                wc == 0x221e || wc == 0x221f ||                  # ∞, ∟
                wc >= 0x222b)) ||                                # ∫ .. ∳
              (wc >= 0x22c0 && wc <= 0x22c3) ||   # N-ary big ops: ⋀, ⋁, ⋂, ⋃
              (wc >= 0x25F8 && wc <= 0x25ff) ||   # ◸ .. ◿
              (wc >= 0x266f &&
               (wc == 0x266f || wc == 0x27d8 || wc == 0x27d9 ||  # ♯, ⟘, ⟙
                (wc >= 0x27c0 && wc <= 0x27c1) ||                # ⟀, ⟁
                (wc >= 0x29b0 && wc <= 0x29b4) ||                # ⦰ .. ⦴
                (wc >= 0x2a00 && wc <= 0x2a06) ||                # ⨀ .. ⨆
                (wc >= 0x2a09 && wc <= 0x2a16) ||                # ⨉ .. ⨖
                wc == 0x2a1b || wc == 0x2a1c)))) ||              # ⨛, ⨜

            (wc >= 0x1d6c1 &&  # variants of \nabla and \partial
             (wc == 0x1d6c1 || wc == 0x1d6db ||
              wc == 0x1d6fb || wc == 0x1d715 ||
              wc == 0x1d735 || wc == 0x1d74f ||
              wc == 0x1d76f || wc == 0x1d789 ||
              wc == 0x1d7a9 || wc == 0x1d7c3)) ||

            # super- and subscript +-=()
            (wc >= 0x207a && wc <= 0x207e) ||
            (wc >= 0x208a && wc <= 0x208e) ||

            # angle symbols
            (wc >= 0x2220 && wc <= 0x2222) ||  # ∠, ∡, ∢
            (wc >= 0x299b && wc <= 0x29af) ||  # ⦛ .. ⦯

            # Other_ID_Start
            wc == 0x2118 || wc == 0x212E ||    # ℘, ℮
            (wc >= 0x309B && wc <= 0x309C) ||  # katakana-hiragana sound marks

            # bold-digits and double-struck digits
            (wc >= 0x1D7CE && wc <= 0x1D7E1))  # 𝟎-𝟗, 𝟘-𝟡
end

function ncg_id_start_char(wc::UInt32)
    (wc >= UInt32('A') && wc <= UInt32('Z')) && return true
    (wc >= UInt32('a') && wc <= UInt32('z')) && return true
    wc == UInt32('_') && return true
    (wc < 0xA1 || wc > 0x10ffff) && return false
    wc == 0x1f8b2 && return true   # Rightwards Arrow with Lower Hook
    return _is_wc_cat_id_start(wc, Int32(UnicodeNext.category_code(wc)))
end

function ncg_id_char(wc::UInt32)
    (wc >= UInt32('A') && wc <= UInt32('Z')) && return true
    (wc >= UInt32('a') && wc <= UInt32('z')) && return true
    (wc >= UInt32('0') && wc <= UInt32('9')) && return true
    (wc == UInt32('_') || wc == UInt32('!')) && return true
    (wc < 0xA1 || wc > 0x10ffff) && return false
    cat = Int32(UnicodeNext.category_code(wc))
    _is_wc_cat_id_start(wc, cat) && return true
    return (cat == _CAT_MN || cat == _CAT_MC ||
            cat == _CAT_ND || cat == _CAT_PC ||
            cat == _CAT_SK || cat == _CAT_ME ||
            cat == _CAT_NO ||
            # primes (single, double, triple, their reverses, and quadruple)
            (wc >= 0x2032 && wc <= 0x2037) || wc == 0x2057 ||
            wc == 0x1f8b2)   # Rightwards Arrow with Lower Hook
end
