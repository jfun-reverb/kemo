# 응모건 메시지 번역 기능 — 서비스 리서치

> **작성일:** 2026-05-21
> **목적:** 응모건 메시지(인플루언서 ↔ 관리자)에 한국어↔일본어 번역을 붙이기 위한 외부 서비스 사전 조사. 관리자(한국어)와 인플루언서(일본어) 간 언어 장벽 해소.
> **상태:** 리서치 단계 (서비스 미선정, 구현 미착수)
> **관련 기능:** `dev/js/messaging.js`, `dev/js/admin-messaging.js`, `application_messages` 테이블 (응모건 메시지 PR 1·2)

---

## 0. 전제 조건

- **언어쌍:** 한국어 ↔ 일본어 양방향
- **대상 텍스트:** 인플루언서의 실제 메시지 (개인정보·브랜드명·이름이 섞일 수 있음)
- **법적 제약:** 한국 개인정보 보호법(PIPA) + 일본 개인정보보호법(APPI) 이중 준수 대상 → 외부 번역 서비스로 메시지를 보내는 것은 **처리위탁·국외이전** 관점에서 약관 검토 필요
- **현재 인프라:** Vercel(정적 호스팅) + Supabase(데이터베이스·인증·저장소·Edge Function). 자체 GPU 서버 없음
- **API 키 보호:** 어떤 서비스든 키 노출을 막으려면 Supabase Edge Function을 경유해 호출하는 구조가 자연스러움 (광고주 알림 메일과 동일 패턴)

---

## 1. 전용 번역기 (전통적 기계번역)

| 서비스 | 무료 한도 | 한↔일 품질 | 개인정보 | 운영 부담 |
|---|---|---|---|---|
| **Microsoft Translator** | **월 200만 자** (영구, 가장 후함) | 양호 | 무료 티어도 학습 미사용 명시 | 낮음 (클라우드) |
| **Google Cloud Translation** | **월 50만 자** (영구 무료, 1년 한정 아님) | 한일 강점, 안정적 | 학습 미사용 | 낮음 (신용카드 등록 필수) |
| **DeepL API Free** | 월 50만 자 | 한일 양호하나 **최근 일본어 품질 하락 보고** | ⚠️ **무료 티어는 번역문을 학습에 사용 가능** | 낮음 |
| **LibreTranslate** | 무제한 (자체 서버 운영 시) | 낮음 | 자체 보관(외부 유출 없음) | ⚠️ 높음 (서버·GPU·수 GB 모델 직접 운영) |
| **MyMemory** | 가입 없이 즉시 | 들쭉날쭉 | — | 없음 (단 **운영 서비스 부적합**, 프로토타입용) |

**핵심:**
- 무료 한도가 압도적으로 큰 것은 **Microsoft Translator (월 200만 자)**
- **DeepL 무료는 부적합** — 번역문이 모델 학습에 사용될 수 있어 개인정보 우려 (이 플랫폼은 개인정보법 이중 준수 대상)
- **LibreTranslate 자체 호스팅은 비추천** — 현재 인프라(GPU 서버 없음)와 안 맞고 품질도 낮음

---

## 2. AI(대규모 언어모델) 번역

전용 번역기보다 **존댓말(일본어 경어)·문맥·뉘앙스 처리에 강점**. 비즈니스 메시지에 유리. 단 무료 한도가 "글자 수"가 아니라 "요청 횟수" 기준이라 사용량 폭증 시 빠르게 막힐 수 있음.

| 옵션 | 무료 여부 | 한↔일 품질 | 한도 방식 | 개인정보 |
|---|---|---|---|---|
| **Google Gemini (Flash-Lite)** | **무료 티어 있음** | 우수 | 횟수 제한 (분당 5~15회, 하루 100~1,500회) | ⚠️ 무료 티어는 학습에 사용될 수 있음 |
| **Gemini Flash-Lite (유료)** | 매우 저렴 (100만 토큰당 약 $0.10~0.40) | 우수 | 사실상 무제한 | 유료는 학습 미사용 |
| **GPT-4o-mini / GPT-4.1** | 유료 (소액 크레딧만) | 우수, 일본어 경어 강점 | 토큰 기반 | 학습 미사용 |
| **Claude API** | 유료 (무료 티어 없음) | 우수 | 토큰 기반 | 학습 미사용 |

**핵심:**
- "AI + 무료"가 동시에 되는 유일한 선택지는 **Google Gemini Flash-Lite 무료 티어**
- 단 무료 티어는 DeepL 무료와 마찬가지로 **내용을 모델 개선(학습)에 사용** → 운영 단계에서는 유료 전환 권장
- Gemini Flash-Lite 유료는 100만 토큰당 약 $0.10~0.40로 매우 저렴 → 실제 메시지 번역 비용은 월 몇 천 원 수준 예상

---

## 3. 설치형 오픈소스 AI (Gemma / TranslateGemma)

- **Gemma**: 구글이 무료 공개한 오픈소스 AI 모델. 상업적 사용 허용
- **TranslateGemma** (2026-01 공개): 번역 전용 Gemma. 55개 언어. 4B(모바일)·12B(노트북)·27B(고성능 GPU) 버전
  - ⚠️ 일→영 번역에서 **고유명사(브랜드명·이름) 오류** 보고 → 인플루언서 메시지엔 브랜드·이름이 자주 나와 주의 필요
  - 한↔일 직접 품질 검증 자료는 불충분

**"설치형"의 함정 — 모델은 무료지만 돌릴 GPU 서버는 유료:**

| 방식 | 비용 구조 | 개인정보 | 운영 부담 | 메시지 번역에 적합? |
|---|---|---|---|---|
| **Gemma 자체 설치** | 월 고정 GPU 비용 (사용량 무관) | ✅ 최고 (데이터 외부 안 나감) | ⚠️ 매우 높음 (GPU·서버 직접 운영, VRAM 20GB+) | ❌ 메시지 양이 들쭉날쭉이라 비효율 |
| **Gemma를 호스팅 API로** (OpenRouter·Groq·Together 등) | 건당 종량제 (100만 토큰당 약 $0.06~0.33) | 업체로 데이터 전송 | 낮음 | 가능하나 한일 품질 검증 필요 |

**핵심:**
- 메시지 번역처럼 사용량이 들쭉날쭉한 용도에선 **자체 설치가 오히려 비효율** (안 쓰는 시간에도 GPU 월세 발생)
- 개인정보를 절대적으로 사내에 가둬야 하고 + 번역량이 매우 많을 때만 자체 설치가 의미 있음
- 현재 단계에선 Gemma 자체 설치보다 Gemini Flash-Lite 또는 Gemma 호스팅 API가 현실적

---

## 4. 종합 결론 (현재 시점 권장 우선순위)

### 무료·간편 우선이면
1. **Google Gemini Flash-Lite (무료 티어)** — AI 품질 + 무료. 단 횟수 제한·학습 사용 주의 → 검증용으로 최적
2. **Microsoft Translator** — 무료 한도 압도적(월 200만 자), 학습 미사용. 전용 번역기 중 가장 안전
3. **Google Cloud Translation** — 한일 안정적, 영구 무료(월 50만 자), 신용카드 등록 필요

### 운영(개인정보 안전) 단계로 가면
- **Gemini Flash-Lite 유료** — 워낙 저렴해 사실상 무료에 가까우면서 학습 미사용. AI 품질 유지
- 또는 **Microsoft / Google Cloud Translation** — 전용 번역기, 학습 미사용, 한도 여유

### 비추천
- **DeepL 무료** (학습 사용 → 개인정보 우려)
- **Gemma 자체 설치** (현재 인프라·사용량 패턴과 불일치)
- **MyMemory** (운영 부적합)

---

## 5. 미결 사항 (다음 단계에서 결정 필요)

1. **서비스 최종 선정** — 실제 한↔일 메시지 샘플로 품질 비교 후 결정 권장
2. **개인정보·약관 영향 검토** — 외부 번역 서비스 = 새 처리위탁 업체 추가 → 개인정보처리방침(PRIVACY) 반영 필요 여부 (`/약관확인`)
3. **구현 UI·동작 설계** — 자동 번역 vs 번역 버튼, 원문/번역문 동시 표시 여부, 번역 결과 저장(캐싱)으로 비용 절감 여부 등 → `reverb-planner`
4. **월 사용량 추정** — 응모건 메시지가 양방향이므로 실제 메시지 건수 기반으로 무료 한도 충분 여부 계산

---

## 출처

- [Best Free Translation APIs in 2026 (Langbly)](https://langbly.com/blog/best-free-translation-api-2026/)
- [Translation API Pricing Comparison (buildmvpfast)](https://www.buildmvpfast.com/api-costs/translation)
- [Google Cloud Translation Pricing](https://cloud.google.com/translate/pricing)
- [DeepL API plans (DeepL Help Center)](https://support.deepl.com/hc/en-us/articles/360021200939-DeepL-API-plans)
- [LibreTranslate (GitHub)](https://github.com/LibreTranslate/LibreTranslate)
- [Gemini API Free Tier 2026 (YingTu)](https://yingtu.ai/en/blog/gemini-api-free-tier)
- [Gemini Developer API Pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [LLM Translation Benchmark 2026 (intlpull)](https://intlpull.com/blog/llm-translation-quality-benchmark-2026)
- [TranslateGemma 공식 발표 (Google Blog)](https://blog.google/innovation-and-ai/technology/developers-tools/translategemma/)
- [Gemma 자체 호스팅 vs API 비용 분석 (AI Cost Check)](https://aicostcheck.com/blog/google-gemma-4-cost-analysis-open-model-2026)
- [Gemma 이용약관 (Google)](https://ai.google.dev/gemma/terms)
