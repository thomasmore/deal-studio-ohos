/**
 * NAPI wrapper for llama.cpp — exposes llamaInit, llamaGenerate, llamaStop, llamaFree
 * (text generation) and llamaEmbedInit, llamaEmbedBatch, llamaEmbedFree (text
 * embedding, a second, independent model+context pair -- see VeraEmbeddings.ets)
 * to ArkTS as the 'llama' native module.
 *
 * Build: place llama.cpp source in entry/src/main/cpp/llama.cpp/ (git clone)
 * The CMakeLists.txt handles linking.
 *
 * When LLAMA_STUB is defined, all functions return failure — allows building
 * the app without llama.cpp for UI development.
 */

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <cmath>
#include <atomic>
#include <mutex>
#include <napi/native_api.h>

#ifndef LLAMA_STUB
#include "llama.h"
#include "common.h"
#endif

static std::atomic<bool> g_stop_flag{false};

#ifndef LLAMA_STUB
static llama_model* g_model = nullptr;
static llama_context* g_ctx = nullptr;
static llama_sampler* g_sampler = nullptr;

// Separate from g_model/g_ctx above: a different GGUF (EmbeddingGemma-300M,
// not the generation model), loaded independently and kept alive for the
// process lifetime once VeraEmbeddings.ets asks for it.
static llama_model* g_embed_model = nullptr;
static llama_context* g_embed_ctx = nullptr;

struct JsonValue {
    std::string str;
    double num = 0;
    bool boolean = false;
    enum Type { String, Number, Bool } type;
};

static std::string json_string(napi_env env, napi_value obj, const char* key) {
    napi_value val;
    if (napi_get_named_property(env, obj, key, &val) != napi_ok) return "";
    size_t len = 0;
    napi_get_value_string_utf8(env, val, nullptr, 0, &len);
    std::string result(len, '\0');
    napi_get_value_string_utf8(env, val, result.data(), len + 1, &len);
    return result;
}

static double json_double(napi_env env, napi_value obj, const char* key, double def) {
    napi_value val;
    if (napi_get_named_property(env, obj, key, &val) != napi_ok) return def;
    double result = def;
    napi_get_value_double(env, val, &result);
    return result;
}

static int json_int(napi_env env, napi_value obj, const char* key, int def) {
    return static_cast<int>(json_double(env, obj, key, def));
}
#endif

// llamaInit(configJson: string): boolean
static napi_value LlamaInit(napi_env env, napi_callback_info info) {
    napi_value result;
#ifdef LLAMA_STUB
    napi_get_boolean(env, false, &result);
    return result;
#else
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // Parse config JSON string
    size_t json_len = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &json_len);
    std::string config_json(json_len, '\0');
    napi_get_value_string_utf8(env, args[0], config_json.data(), json_len + 1, &json_len);

    // Parse JSON with napi (convert string to object)
    napi_value global, json_obj, parse_fn, config_val;
    napi_get_global(env, &global);
    napi_get_named_property(env, global, "JSON", &json_obj);
    napi_get_named_property(env, json_obj, "parse", &parse_fn);
    napi_value json_str;
    napi_create_string_utf8(env, config_json.c_str(), config_json.size(), &json_str);
    napi_call_function(env, json_obj, parse_fn, 1, &json_str, &config_val);

    std::string model_path = json_string(env, config_val, "model_path");
    int n_ctx = json_int(env, config_val, "n_ctx", 16384);
    int n_threads = json_int(env, config_val, "n_threads", 4);
    int n_gpu_layers = json_int(env, config_val, "n_gpu_layers", 0);

    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
    if (g_ctx) { llama_free(g_ctx); g_ctx = nullptr; }
    if (g_sampler) { llama_sampler_free(g_sampler); g_sampler = nullptr; }

    auto mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;
    g_model = llama_model_load_from_file(model_path.c_str(), mparams);
    if (!g_model) {
        napi_get_boolean(env, false, &result);
        return result;
    }

    auto cparams = llama_context_default_params();
    cparams.n_ctx = n_ctx;
    // The prompt is decoded as one batch (LlamaGenerate), and llama_decode refuses a batch over n_batch (2048 by default).
    cparams.n_batch = n_ctx;
    cparams.n_threads = n_threads;
    cparams.n_threads_batch = n_threads;
    g_ctx = llama_init_from_model(g_model, cparams);
    if (!g_ctx) {
        llama_model_free(g_model); g_model = nullptr;
        napi_get_boolean(env, false, &result);
        return result;
    }

    g_sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(g_sampler, llama_sampler_init_top_p(0.95f, 1));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_temp(0.2f));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_dist(42));

    napi_get_boolean(env, true, &result);
    return result;
#endif
}

// llamaGenerate(paramsJson: string, callback: (token: string) => void): {text, inputTokens, outputTokens}
static napi_value LlamaGenerate(napi_env env, napi_callback_info info) {
#ifdef LLAMA_STUB
    napi_value result_obj;
    napi_create_object(env, &result_obj);
    napi_value empty_str, zero_val;
    napi_create_string_utf8(env, "", 0, &empty_str);
    napi_create_int32(env, 0, &zero_val);
    napi_set_named_property(env, result_obj, "text", empty_str);
    napi_set_named_property(env, result_obj, "inputTokens", zero_val);
    napi_set_named_property(env, result_obj, "outputTokens", zero_val);
    return result_obj;
#else
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // Parse params
    size_t json_len = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &json_len);
    std::string params_json(json_len, '\0');
    napi_get_value_string_utf8(env, args[0], params_json.data(), json_len + 1, &json_len);

    napi_value global, json_obj, parse_fn, params_val;
    napi_get_global(env, &global);
    napi_get_named_property(env, global, "JSON", &json_obj);
    napi_get_named_property(env, json_obj, "parse", &parse_fn);
    napi_value jstr;
    napi_create_string_utf8(env, params_json.c_str(), params_json.size(), &jstr);
    napi_call_function(env, json_obj, parse_fn, 1, &jstr, &params_val);

    std::string prompt = json_string(env, params_val, "prompt");
    std::string grammar_str = json_string(env, params_val, "grammar");
    int max_tokens = json_int(env, params_val, "max_tokens", 2048);

    napi_value callback = args[1];

    if (!g_model || !g_ctx) {
        napi_value result_obj;
        napi_create_object(env, &result_obj);
        napi_value empty_str, zero_val;
        napi_create_string_utf8(env, "", 0, &empty_str);
        napi_create_int32(env, 0, &zero_val);
        napi_set_named_property(env, result_obj, "text", empty_str);
        napi_set_named_property(env, result_obj, "inputTokens", zero_val);
        napi_set_named_property(env, result_obj, "outputTokens", zero_val);
        return result_obj;
    }

    // Tokenize prompt
    auto vocab = llama_model_get_vocab(g_model);
    int n_prompt = llama_tokenize(vocab, prompt.c_str(), prompt.size(), nullptr, 0, true, true);
    std::vector<llama_token> tokens(n_prompt);
    llama_tokenize(vocab, prompt.c_str(), prompt.size(), tokens.data(), tokens.size(), true, true);

    // Set up grammar if provided -- llama_grammar_init_impl (the raw grammar
    // object this was written against) is gone from current llama.cpp;
    // grammar is a sampler now, chained ahead of the usual top_p/temp/dist
    // sampler g_sampler already holds. A fresh chain only when a grammar is
    // actually requested, since g_sampler is built once in LlamaInit and
    // reused for every call that doesn't need one.
    llama_sampler* active_sampler = g_sampler;
    llama_sampler* grammar_chain = nullptr;
    if (!grammar_str.empty()) {
        grammar_chain = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler* grammar_sampler = llama_sampler_init_grammar(vocab, grammar_str.c_str(), "root");
        if (grammar_sampler) { llama_sampler_chain_add(grammar_chain, grammar_sampler); }
        llama_sampler_chain_add(grammar_chain, llama_sampler_init_top_p(0.95f, 1));
        llama_sampler_chain_add(grammar_chain, llama_sampler_init_temp(0.2f));
        llama_sampler_chain_add(grammar_chain, llama_sampler_init_dist(42));
        active_sampler = grammar_chain;
    }

    // Decode prompt -- llama_kv_cache_clear is gone too; memory is addressed
    // through llama_get_memory now.
    llama_memory_clear(llama_get_memory(g_ctx), true);
    llama_batch batch = llama_batch_get_one(tokens.data(), tokens.size());
    llama_decode(g_ctx, batch);

    // Generate
    g_stop_flag.store(false);
    std::string full_output;
    int output_token_count = 0;

    for (int i = 0; i < max_tokens && !g_stop_flag.load(); i++) {
        llama_token new_token = llama_sampler_sample(active_sampler, g_ctx, -1);
        llama_sampler_accept(active_sampler, new_token);

        if (llama_vocab_is_eog(vocab, new_token)) break;

        char buf[256];
        int n = llama_token_to_piece(vocab, new_token, buf, sizeof(buf), 0, true);
        if (n > 0) {
            std::string piece(buf, n);
            full_output += piece;
            output_token_count++;

            // Stream token to callback
            napi_value token_str, cb_result;
            napi_create_string_utf8(env, piece.c_str(), piece.size(), &token_str);
            napi_value undef;
            napi_get_undefined(env, &undef);
            napi_call_function(env, undef, callback, 1, &token_str, &cb_result);
        }

        // Prepare next decode
        llama_batch next_batch = llama_batch_get_one(&new_token, 1);
        llama_decode(g_ctx, next_batch);
    }

    if (grammar_chain) llama_sampler_free(grammar_chain);

    napi_value result_obj;
    napi_create_object(env, &result_obj);
    napi_value text_val;
    napi_create_string_utf8(env, full_output.c_str(), full_output.size(), &text_val);
    napi_set_named_property(env, result_obj, "text", text_val);
    napi_value input_tokens_val;
    napi_create_int32(env, n_prompt, &input_tokens_val);
    napi_set_named_property(env, result_obj, "inputTokens", input_tokens_val);
    napi_value output_tokens_val;
    napi_create_int32(env, output_token_count, &output_tokens_val);
    napi_set_named_property(env, result_obj, "outputTokens", output_tokens_val);
    return result_obj;
#endif
}

// The embedding model runs on a worker thread (napi_async_work): a single long text took over 6 s on the
// phone's CPU, and on the UI thread that is a THREAD_BLOCK_6S kill (appfreeze-...-20261028185007). The
// model and its context are touched only under g_embed_mutex: a load, a batch and a free never overlap.
#ifndef LLAMA_STUB
static std::mutex g_embed_mutex;

// Loads the model and context; false leaves both null. Caller holds g_embed_mutex.
static bool embed_load(const std::string& model_path, int n_ctx, int n_threads) {
    if (g_embed_ctx) { llama_free(g_embed_ctx); g_embed_ctx = nullptr; }
    if (g_embed_model) { llama_model_free(g_embed_model); g_embed_model = nullptr; }

    auto mparams = llama_model_default_params();
    g_embed_model = llama_model_load_from_file(model_path.c_str(), mparams);
    if (!g_embed_model) { return false; }

    auto cparams = llama_context_default_params();
    cparams.n_ctx = n_ctx;
    // EmbeddingGemma is a non-causal (bidirectional) model -- llama.cpp's own
    // embedding example sets n_ubatch == n_batch for exactly this case
    // (examples/embedding/embedding.cpp), so both are pinned to n_ctx here
    // rather than left at the (causal-generation-sized) defaults.
    cparams.n_batch = n_ctx;
    cparams.n_ubatch = n_ctx;
    cparams.n_threads = n_threads;
    cparams.n_threads_batch = n_threads;
    cparams.embeddings = true;
    cparams.pooling_type = LLAMA_POOLING_TYPE_MEAN;
    g_embed_ctx = llama_init_from_model(g_embed_model, cparams);
    if (!g_embed_ctx) {
        llama_model_free(g_embed_model); g_embed_model = nullptr;
        return false;
    }
    return true;
}

// One L2-normalized vector per text, in order; a text that fails to embed (too long for n_ctx,
// decode error) is an empty vector. Caller holds g_embed_mutex.
static std::vector<std::vector<float>> embed_texts(const std::vector<std::string>& texts) {
    std::vector<std::vector<float>> out(texts.size());
    if (!g_embed_model || !g_embed_ctx) { return out; }
    auto vocab = llama_model_get_vocab(g_embed_model);
    int n_embd = llama_model_n_embd_out(g_embed_model);
    int n_ctx = llama_n_ctx(g_embed_ctx);
    for (size_t i = 0; i < texts.size(); i++) {
        const std::string& text = texts[i];
        int n_tok = llama_tokenize(vocab, text.c_str(), text.size(), nullptr, 0, true, true);
        int n_tok_abs = n_tok < 0 ? -n_tok : n_tok;
        if (n_tok_abs == 0 || n_tok_abs > n_ctx) { continue; }
        std::vector<llama_token> tokens(n_tok_abs);
        llama_tokenize(vocab, text.c_str(), text.size(), tokens.data(), tokens.size(), true, true);

        llama_memory_clear(llama_get_memory(g_embed_ctx), true);
        llama_batch batch = llama_batch_get_one(tokens.data(), tokens.size());
        // llama.cpp's own batch validation marks every token as needing
        // output when embeddings are requested but none were explicitly
        // flagged (src/llama-batch.cpp), which is exactly the case here --
        // llama_batch_get_one leaves `logits` null, same shape LlamaGenerate
        // already relies on for the single-sequence case.
        if (llama_decode(g_embed_ctx, batch) != 0) { continue; }
        const float* embd = llama_get_embeddings_seq(g_embed_ctx, 0);
        if (!embd) { continue; }

        double sum_sq = 0;
        for (int d = 0; d < n_embd; d++) { sum_sq += static_cast<double>(embd[d]) * embd[d]; }
        double norm = std::sqrt(sum_sq);
        out[i].resize(n_embd);
        for (int d = 0; d < n_embd; d++) { out[i][d] = norm > 0 ? static_cast<float>(embd[d] / norm) : 0.0f; }
    }
    return out;
}
#endif

struct EmbedInitWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string model_path;
    int n_ctx = 512;
    int n_threads = 4;
    bool ok = false;
};

// llamaEmbedInit(configJson: string): Promise<boolean>
// config: { model_path, n_ctx, n_threads }
static napi_value LlamaEmbedInit(napi_env env, napi_callback_info info) {
    napi_value promise;
    auto* job = new EmbedInitWork();
    napi_create_promise(env, &job->deferred, &promise);
#ifndef LLAMA_STUB
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    size_t json_len = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &json_len);
    std::string config_json(json_len, '\0');
    napi_get_value_string_utf8(env, args[0], config_json.data(), json_len + 1, &json_len);

    napi_value global, json_obj, parse_fn, config_val;
    napi_get_global(env, &global);
    napi_get_named_property(env, global, "JSON", &json_obj);
    napi_get_named_property(env, json_obj, "parse", &parse_fn);
    napi_value json_str;
    napi_create_string_utf8(env, config_json.c_str(), config_json.size(), &json_str);
    napi_call_function(env, json_obj, parse_fn, 1, &json_str, &config_val);

    job->model_path = json_string(env, config_val, "model_path");
    job->n_ctx = json_int(env, config_val, "n_ctx", 512);
    job->n_threads = json_int(env, config_val, "n_threads", 4);
#endif
    napi_value name;
    napi_create_string_utf8(env, "llamaEmbedInit", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name,
        [](napi_env, void* data) {
#ifndef LLAMA_STUB
            auto* j = static_cast<EmbedInitWork*>(data);
            std::lock_guard<std::mutex> lock(g_embed_mutex);
            j->ok = embed_load(j->model_path, j->n_ctx, j->n_threads);
#endif
        },
        [](napi_env env, napi_status, void* data) {
            auto* j = static_cast<EmbedInitWork*>(data);
            napi_value ok;
            napi_get_boolean(env, j->ok, &ok);
            napi_resolve_deferred(env, j->deferred, ok);
            napi_delete_async_work(env, j->work);
            delete j;
        },
        job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}

struct EmbedBatchWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::vector<std::string> texts;
    std::vector<std::vector<float>> vecs;
};

// llamaEmbedBatch(texts: string[]): Promise<number[][]>
// One L2-normalized vector per input text, in order; a text that fails to
// embed (too long for n_ctx, decode error) comes back as an empty array --
// VeraEmbeddings.ets treats that element as "skip", never as a reason to
// fail the whole batch. The texts are copied on the UI thread, embedded on a
// worker, and turned back into arrays on the UI thread.
static napi_value LlamaEmbedBatch(napi_env env, napi_callback_info info) {
    napi_value promise;
    auto* job = new EmbedBatchWork();
    napi_create_promise(env, &job->deferred, &promise);
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t n_texts = 0;
    napi_get_array_length(env, args[0], &n_texts);
    for (uint32_t i = 0; i < n_texts; i++) {
        napi_value item_val;
        napi_get_element(env, args[0], i, &item_val);
        size_t len = 0;
        napi_get_value_string_utf8(env, item_val, nullptr, 0, &len);
        std::string text(len, '\0');
        napi_get_value_string_utf8(env, item_val, text.data(), len + 1, &len);
        job->texts.push_back(text);
    }
    job->vecs.resize(job->texts.size());

    napi_value name;
    napi_create_string_utf8(env, "llamaEmbedBatch", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name,
        [](napi_env, void* data) {
#ifndef LLAMA_STUB
            auto* j = static_cast<EmbedBatchWork*>(data);
            std::lock_guard<std::mutex> lock(g_embed_mutex);
            j->vecs = embed_texts(j->texts);
#endif
        },
        [](napi_env env, napi_status, void* data) {
            auto* j = static_cast<EmbedBatchWork*>(data);
            napi_value out_array;
            napi_create_array_with_length(env, j->vecs.size(), &out_array);
            for (size_t i = 0; i < j->vecs.size(); i++) {
                napi_value vec_val;
                napi_create_array_with_length(env, j->vecs[i].size(), &vec_val);
                for (size_t d = 0; d < j->vecs[i].size(); d++) {
                    napi_value num_val;
                    napi_create_double(env, j->vecs[i][d], &num_val);
                    napi_set_element(env, vec_val, d, num_val);
                }
                napi_set_element(env, out_array, i, vec_val);
            }
            napi_resolve_deferred(env, j->deferred, out_array);
            napi_delete_async_work(env, j->work);
            delete j;
        },
        job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}

// llamaEmbedFree(): void -- waits for a load or batch in progress.
static napi_value LlamaEmbedFree(napi_env env, napi_callback_info info) {
#ifndef LLAMA_STUB
    std::lock_guard<std::mutex> lock(g_embed_mutex);
    if (g_embed_ctx) { llama_free(g_embed_ctx); g_embed_ctx = nullptr; }
    if (g_embed_model) { llama_model_free(g_embed_model); g_embed_model = nullptr; }
#endif
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

// llamaScanCorpus(query: number[], corpus: Float32Array, dimension: number, count: number): Float32Array
// Dot product of `query` (length `dimension`) against each of `count`
// `dimension`-wide rows of `corpus`, one score per row, in corpus order --
// the inner loop VeraSdkEmbeddingCache.ets's findSdkFunctionByEmbedding
// used to run itself, in ArkTS: ~584ms on-device for 16,511 x 768 (~12.7M
// multiply-adds), because an interpreted per-element loop over a plain
// number[] never vectorizes. Compiled C++ reading `corpus` directly out of
// the Float32Array's backing buffer (no copy) lets the compiler
// auto-vectorize the multiply-add; sorting the (small, 16,511-long) scores
// array stays in ArkTS, since that part was never the measured cost.
//
// `count` is passed explicitly rather than derived from the typed array's
// own reported length: a first version computed it as corpus_len/dimension
// from napi_get_typedarray_info's length output and crashed on-device
// (SIGSEGV reading past the real buffer) -- that length's units didn't
// match what was assumed here. The actual byte length of the backing
// ArrayBuffer (napi_get_arraybuffer_info, unambiguous) is used below only
// as a hard safety clamp, never as the primary source of `count`.
//
// Does not touch llama.h / the model at all -- pure NAPI + arithmetic, so
// unlike every function above it this one needs no LLAMA_STUB guard; it
// compiles and runs identically with or without llama.cpp present.
static napi_value LlamaScanCorpus(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_value empty;
        napi_create_arraybuffer(env, 0, nullptr, &empty);
        napi_value empty_arr;
        napi_create_typedarray(env, napi_float32_array, 0, empty, 0, &empty_arr);
        return empty_arr;
    }

    double dimension_d = 0, count_d = 0;
    napi_get_value_double(env, args[2], &dimension_d);
    napi_get_value_double(env, args[3], &count_d);
    uint32_t dimension = dimension_d > 0 ? static_cast<uint32_t>(dimension_d) : 0;
    uint32_t requested_count = count_d > 0 ? static_cast<uint32_t>(count_d) : 0;

    uint32_t q_len = 0;
    napi_get_array_length(env, args[0], &q_len);
    std::vector<float> query(dimension, 0.0f);
    uint32_t q_n = q_len < dimension ? q_len : dimension;
    for (uint32_t d = 0; d < q_n; d++) {
        napi_value el;
        napi_get_element(env, args[0], d, &el);
        double v = 0;
        napi_get_value_double(env, el, &v);
        query[d] = static_cast<float>(v);
    }

    napi_typedarray_type type;
    size_t typedarray_len = 0;
    void* corpus_data = nullptr;
    napi_value src_arraybuffer;
    size_t byte_offset = 0;
    napi_get_typedarray_info(env, args[1], &type, &typedarray_len, &corpus_data, &src_arraybuffer, &byte_offset);
    const float* corpus = static_cast<const float*>(corpus_data);

    void* ab_data = nullptr;
    size_t ab_byte_len = 0;
    napi_get_arraybuffer_info(env, src_arraybuffer, &ab_data, &ab_byte_len);
    size_t safe_byte_len = byte_offset <= ab_byte_len ? (ab_byte_len - byte_offset) : 0;
    uint32_t max_count_from_buffer = dimension > 0
        ? static_cast<uint32_t>(safe_byte_len / (static_cast<size_t>(dimension) * sizeof(float)))
        : 0;

    uint32_t count = requested_count < max_count_from_buffer ? requested_count : max_count_from_buffer;
    if (corpus == nullptr || dimension == 0) { count = 0; }

    napi_value out_buffer;
    void* out_data = nullptr;
    napi_create_arraybuffer(env, static_cast<size_t>(count) * sizeof(float), &out_data, &out_buffer);
    float* scores = static_cast<float*>(out_data);

    for (uint32_t i = 0; i < count; i++) {
        const float* row = corpus + static_cast<size_t>(i) * dimension;
        float dot = 0.0f;
        for (uint32_t d = 0; d < dimension; d++) { dot += query[d] * row[d]; }
        scores[i] = dot;
    }

    napi_value out_array;
    napi_create_typedarray(env, napi_float32_array, count, out_buffer, 0, &out_array);
    return out_array;
}

// llamaStop(): void
static napi_value LlamaStop(napi_env env, napi_callback_info info) {
    g_stop_flag.store(true);
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

// llamaFree(): void
static napi_value LlamaFree(napi_env env, napi_callback_info info) {
#ifndef LLAMA_STUB
    if (g_sampler) { llama_sampler_free(g_sampler); g_sampler = nullptr; }
    if (g_ctx) { llama_free(g_ctx); g_ctx = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
#endif
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

// llamaBuildInfo(): string
// "stub" when the module was built without llama.cpp, otherwise "llama.cpp "
// and the commit it was built from -- so the app can say plainly that model
// support is missing instead of failing every load in silence.
static napi_value LlamaBuildInfo(napi_env env, napi_callback_info info) {
    napi_value result;
#ifdef LLAMA_STUB
    const char *text = "stub";
#elif defined(VERA_LLAMA_COMMIT)
    const char *text = "llama.cpp " VERA_LLAMA_COMMIT;
#else
    const char *text = "llama.cpp";
#endif
    napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &result);
    return result;
}

// Module registration
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"llamaInit", nullptr, LlamaInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"llamaGenerate", nullptr, LlamaGenerate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"llamaStop", nullptr, LlamaStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"llamaFree", nullptr, LlamaFree, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"llamaEmbedInit", nullptr, LlamaEmbedInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"llamaEmbedBatch", nullptr, LlamaEmbedBatch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"llamaEmbedFree", nullptr, LlamaEmbedFree, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"llamaScanCorpus", nullptr, LlamaScanCorpus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"llamaBuildInfo", nullptr, LlamaBuildInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

EXTERN_C_START
static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "llama",
    .nm_priv = nullptr,
    .reserved = {0},
};

__attribute__((constructor)) void RegisterModule(void) {
    napi_module_register(&g_module);
}
EXTERN_C_END
