#include <dlfcn.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t column_count, row_count, rows_changed;
    void *columns;
    char *error;
    void *internal;
} QDuckResult;

typedef union {
    struct { uint32_t length; char prefix[4]; char *pointer; } pointer;
    struct { uint32_t length; char data[12]; } inlined;
} QDuckString;


typedef struct {
    void *library, *database, *connection;
    QDuckResult result;
    bool has_result;
    char *error;
    void (*free_value)(void *);
    int (*query)(void *, const char *, QDuckResult *);
    void (*destroy_result)(QDuckResult *);
    uint64_t (*row_count)(QDuckResult *);
    int (*column_type)(QDuckResult *, uint64_t);
    void *chunk;
    uint64_t chunk_start, chunk_size;
    void *(*fetch_chunk)(QDuckResult);
    void (*destroy_chunk)(void **);
    uint64_t (*chunk_rows)(void *);
    void *(*chunk_vector)(void *, uint64_t);
    void *(*vector_data)(void *);
    uint64_t *(*vector_validity)(void *);
    uint32_t (*string_length)(QDuckString);
    const char *(*string_data)(QDuckString *);
    void *(*allocate)(size_t);
    const char *(*result_error)(QDuckResult *);
    void (*interrupt)(void *);
    void (*disconnect)(void **);
    void (*close)(void **);
} QDuck;

static void qduck_error(QDuck *q, const char *message) {
    free(q->error);
    q->error = strdup(message ? message : "Could not query DuckDB");
}

void *quanta_duck_open(const char *library, const char *path) {
    QDuck *q = calloc(1, sizeof(QDuck));
    if (!q) return NULL;
    q->library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!q->library) { qduck_error(q, dlerror()); return q; }
    int (*create_config)(void **) = dlsym(q->library, "duckdb_create_config");
    int (*set_config)(void *, const char *, const char *) = dlsym(q->library, "duckdb_set_config");
    void (*destroy_config)(void **) = dlsym(q->library, "duckdb_destroy_config");
    int (*open_ext)(const char *, void **, void *, char **) = dlsym(q->library, "duckdb_open_ext");
    int (*connect_db)(void *, void **) = dlsym(q->library, "duckdb_connect");
    q->free_value = dlsym(q->library, "duckdb_free");
    q->query = dlsym(q->library, "duckdb_query");
    q->destroy_result = dlsym(q->library, "duckdb_destroy_result");
    q->row_count = dlsym(q->library, "duckdb_row_count");
    q->column_type = dlsym(q->library, "duckdb_column_type");
    q->fetch_chunk = dlsym(q->library, "duckdb_fetch_chunk");
    q->destroy_chunk = dlsym(q->library, "duckdb_destroy_data_chunk");
    q->chunk_rows = dlsym(q->library, "duckdb_data_chunk_get_size");
    q->chunk_vector = dlsym(q->library, "duckdb_data_chunk_get_vector");
    q->vector_data = dlsym(q->library, "duckdb_vector_get_data");
    q->vector_validity = dlsym(q->library, "duckdb_vector_get_validity");
    q->string_length = dlsym(q->library, "duckdb_string_t_length");
    q->string_data = dlsym(q->library, "duckdb_string_t_data");
    q->allocate = dlsym(q->library, "duckdb_malloc");
    q->result_error = dlsym(q->library, "duckdb_result_error");
    q->interrupt = dlsym(q->library, "duckdb_interrupt");
    q->disconnect = dlsym(q->library, "duckdb_disconnect");
    q->close = dlsym(q->library, "duckdb_close");
    if (!create_config || !set_config || !destroy_config || !open_ext || !connect_db || !q->free_value || !q->query || !q->destroy_result || !q->row_count || !q->column_type || !q->fetch_chunk || !q->destroy_chunk || !q->chunk_rows || !q->chunk_vector || !q->vector_data || !q->vector_validity || !q->string_length || !q->string_data || !q->allocate || !q->result_error || !q->interrupt || !q->disconnect || !q->close) {
        qduck_error(q, "The bundled DuckDB library is incompatible"); return q;
    }
    void *config = NULL;
    if (create_config(&config)) { qduck_error(q, "Could not configure DuckDB"); return q; }
    int failed = 0;
    failed |= set_config(config, "memory_limit", "128MB");
    failed |= set_config(config, "threads", "2");
    failed |= set_config(config, "max_temp_directory_size", "0B");
    failed |= set_config(config, "autoinstall_known_extensions", "false");
    failed |= set_config(config, "autoload_known_extensions", "false");
    if (path && path[0]) failed |= set_config(config, "access_mode", "READ_ONLY");
    char *error = NULL;
    if (failed || open_ext(path && path[0] ? path : NULL, &q->database, config, &error)) {
        qduck_error(q, error ? error : "Could not configure DuckDB");
    } else if (connect_db(q->database, &q->connection)) { qduck_error(q, "Could not connect to DuckDB"); }
    if (error) q->free_value(error);
    destroy_config(&config);
    return q;
}

const char *quanta_duck_error(void *handle) { return handle ? ((QDuck *)handle)->error : "Could not allocate DuckDB connection"; }
int quanta_duck_query(void *handle, const char *sql) {
    QDuck *q = handle;
    if (!q || !q->connection) return 1;
    free(q->error); q->error = NULL;
    if (q->chunk) q->destroy_chunk(&q->chunk);
    q->chunk_start = 0; q->chunk_size = 0;
    if (q->has_result) q->destroy_result(&q->result);
    memset(&q->result, 0, sizeof(QDuckResult));
    q->has_result = true;
    if (q->query(q->connection, sql, &q->result)) { qduck_error(q, q->result_error(&q->result)); return 1; }
    return 0;
}
uint64_t quanta_duck_rows(void *handle) { QDuck *q = handle; return q->row_count(&q->result); }
char *quanta_duck_value(void *handle, uint64_t column, uint64_t row, uint64_t *length) {
    QDuck *q = handle;
    *length = 0;
    if (q->column_type(&q->result, column) != 17) { qduck_error(q, "Preview columns must be converted to text"); return NULL; }
    while (!q->chunk || row >= q->chunk_start + q->chunk_size) {
        q->chunk_start += q->chunk_size;
        if (q->chunk) q->destroy_chunk(&q->chunk);
        q->chunk = q->fetch_chunk(q->result);
        if (!q->chunk) { qduck_error(q, "Could not read result page"); return NULL; }
        q->chunk_size = q->chunk_rows(q->chunk);
    }
    if (row < q->chunk_start) { qduck_error(q, "Result rows must be read in order"); return NULL; }
    uint64_t index = row - q->chunk_start;
    void *vector = q->chunk_vector(q->chunk, column);
    uint64_t *validity = q->vector_validity(vector);
    if (validity && !(validity[index / 64] & ((uint64_t)1 << (index % 64)))) return NULL;
    QDuckString *strings = q->vector_data(vector);
    *length = q->string_length(strings[index]);
    if (*length > 4 * 1024 * 1024) { qduck_error(q, "A value exceeds the 4 MB preview limit"); return NULL; }
    char *copy = q->allocate(*length + 1);
    if (!copy) { qduck_error(q, "Could not allocate a preview value"); return NULL; }
    memcpy(copy, q->string_data(&strings[index]), *length);
    copy[*length] = 0;
    return copy;
}
void quanta_duck_free(void *handle, void *value) { ((QDuck *)handle)->free_value(value); }
void quanta_duck_interrupt(void *handle) { QDuck *q = handle; if (q && q->connection) q->interrupt(q->connection); }
void quanta_duck_close(void *handle) {
    QDuck *q = handle;
    if (!q) return;
    if (q->chunk) q->destroy_chunk(&q->chunk);
    q->chunk_start = 0; q->chunk_size = 0;
    if (q->has_result) q->destroy_result(&q->result);
    if (q->connection) q->disconnect(&q->connection);
    if (q->database) q->close(&q->database);
    if (q->library) dlclose(q->library);
    free(q->error);
    free(q);
}
int quanta_duck_validate(void *handle, const char *sql) {
    QDuck *q = handle;
    uint64_t (*extract)(void *, const char *, void **) = dlsym(q->library, "duckdb_extract_statements");
    int (*prepare)(void *, void *, uint64_t, void **) = dlsym(q->library, "duckdb_prepare_extracted_statement");
    int (*type)(void *) = dlsym(q->library, "duckdb_prepared_statement_type");
    void (*destroy)(void **) = dlsym(q->library, "duckdb_destroy_extracted");
    void (*destroy_prepared)(void **) = dlsym(q->library, "duckdb_destroy_prepare");
    if (!extract || !prepare || !type || !destroy || !destroy_prepared) return 1;
    void *statements = NULL, *statement = NULL;
    uint64_t count = extract(q->connection, sql, &statements);
    int failed = count != 1 || prepare(q->connection, statements, 0, &statement) || type(statement) != 1;
    if (statement) destroy_prepared(&statement);
    if (statements) destroy(&statements);
    if (failed) qduck_error(q, "Enter one read-only SELECT query. This browser does not modify databases.");
    return failed;
}
