/*
 * Z-05 sample JAR —— 数据开发计算任务参考实现。
 *
 * 运行契约（与 data-sandbox-jar-runner 一致）：
 *   java -jar datadev-sample-<v>.jar --input <csv> --output <csv> [--params <json>]
 *   - 读取 --input CSV（首行为表头），按 --params 过滤/聚合，结果写 --output CSV（utf-8）。
 *   - --params JSON 字段：
 *       filterColumn/filterValue ：按指定列等值过滤（可选）
 *       groupColumn             ：聚合分组列（可选）；设置后输出 group,count,sum(sumColumn)
 *       sumColumn               ：聚合求和数值列（groupColumn 存在时生效）
 *   - 参数也可经环境变量 DS_PARAMS_JSON 注入（--params 优先）。
 */
package com.example;

import java.io.BufferedWriter;
import java.io.BufferedReader;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class DataDevSample {

    public static void main(String[] args) throws Exception {
        Map<String, String> opts = parseArgs(args);
        String input = opts.get("--input");
        String output = opts.get("--output");
        if (input == null || output == null) {
            System.err.println("usage: java -jar datadev-sample.jar --input <csv> --output <csv> [--params <json>]");
            System.exit(2);
        }
        String paramsJson = opts.get("--params");
        if (paramsJson == null || paramsJson.isBlank()) {
            paramsJson = System.getenv("DS_PARAMS_JSON");
        }
        Map<String, String> params = parseJson(paramsJson == null ? "{}" : paramsJson);

        List<String[]> table = readCsv(Path.of(input));
        if (table.isEmpty()) {
            writeCsv(Path.of(output), new String[]{"group", "count", "sum"}, new ArrayList<>());
            return;
        }
        String[] header = table.get(0);
        List<String[]> data = table.subList(1, table.size());

        // 可选等值过滤
        String filterColumn = params.get("filterColumn");
        String filterValue = params.get("filterValue");
        if (filterColumn != null && filterValue != null) {
            int idx = indexOf(header, filterColumn);
            if (idx < 0) {
                throw new IllegalArgumentException("filterColumn not found: " + filterColumn);
            }
            List<String[]> filtered = new ArrayList<>();
            for (String[] row : data) {
                if (filterValue.equals(row[idx])) {
                    filtered.add(row);
                }
            }
            data = filtered;
        }

        String groupColumn = params.get("groupColumn");
        if (groupColumn == null || groupColumn.isBlank()) {
            // 透传过滤结果：原表头 + 行
            writeCsv(Path.of(output), header, data);
            return;
        }

        // 聚合：group,count,sum(sumColumn)
        int groupIdx = indexOf(header, groupColumn);
        if (groupIdx < 0) {
            throw new IllegalArgumentException("groupColumn not found: " + groupColumn);
        }
        String sumColumn = params.get("sumColumn");
        int sumIdx = sumColumn == null ? -1 : indexOf(header, sumColumn);
        Map<String, double[]> agg = new LinkedHashMap<>(); // group -> {count, sum}
        List<String> order = new ArrayList<>();
        for (String[] row : data) {
            String key = row[groupIdx];
            if (!agg.containsKey(key)) {
                agg.put(key, new double[]{0, 0});
                order.add(key);
            }
            agg.get(key)[0] += 1;
            if (sumIdx >= 0) {
                try {
                    agg.get(key)[1] += Double.parseDouble(row[sumIdx]);
                } catch (NumberFormatException ignored) {
                    // 非数值列忽略
                }
            }
        }
        List<String[]> out = new ArrayList<>();
        for (String key : order) {
            double[] v = agg.get(key);
            out.add(new String[]{key, String.valueOf((long) v[0]),
                    sumIdx >= 0 ? String.format("%.2f", v[1]) : ""});
        }
        writeCsv(Path.of(output), new String[]{"group", "count", "sum"}, out);
    }

    private static Map<String, String> parseArgs(String[] args) {
        Map<String, String> opts = new HashMap<>();
        for (int i = 0; i + 1 < args.length; i++) {
            if (args[i].startsWith("--")) {
                opts.put(args[i], args[i + 1]);
                i++;
            }
        }
        return opts;
    }

    private static int indexOf(String[] header, String name) {
        for (int i = 0; i < header.length; i++) {
            if (name.equals(header[i])) {
                return i;
            }
        }
        return -1;
    }

    private static List<String[]> readCsv(Path path) throws IOException {
        List<String[]> rows = new ArrayList<>();
        try (BufferedReader reader = Files.newBufferedReader(path, StandardCharsets.UTF_8)) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.isBlank()) {
                    continue;
                }
                rows.add(splitCsv(line));
            }
        }
        return rows;
    }

    private static void writeCsv(Path path, String[] header, List<String[]> rows) throws IOException {
        try (BufferedWriter writer = Files.newBufferedWriter(path, StandardCharsets.UTF_8)) {
            writer.write(String.join(",", header));
            writer.newLine();
            for (String[] row : rows) {
                writer.write(String.join(",", row));
                writer.newLine();
            }
        }
    }

    /** 极简 CSV 行解析：处理双引号包裹（含内部逗号）。 */
    private static String[] splitCsv(String line) {
        List<String> cols = new ArrayList<>();
        StringBuilder cur = new StringBuilder();
        boolean inQuote = false;
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (c == '"') {
                if (inQuote && i + 1 < line.length() && line.charAt(i + 1) == '"') {
                    cur.append('"');
                    i++;
                } else {
                    inQuote = !inQuote;
                }
            } else if (c == ',' && !inQuote) {
                cols.add(cur.toString());
                cur.setLength(0);
            } else {
                cur.append(c);
            }
        }
        cols.add(cur.toString());
        return cols.toArray(new String[0]);
    }

    /** 极简 JSON 对象解析：{"k":"v","k2":"v2"}，仅字符串值（够用即可）。 */
    private static Map<String, String> parseJson(String json) {
        Map<String, String> result = new HashMap<>();
        String s = json.trim();
        if (s.isEmpty() || s.equals("{}")) {
            return result;
        }
        int start = s.indexOf('{');
        int end = s.lastIndexOf('}');
        if (start < 0 || end < start) {
            return result;
        }
        String body = s.substring(start + 1, end);
        StringBuilder key = new StringBuilder();
        StringBuilder value = new StringBuilder();
        boolean inKey = true;
        boolean inQuote = false;
        for (int i = 0; i < body.length(); i++) {
            char c = body.charAt(i);
            if (c == '"') {
                inQuote = !inQuote;
            } else if (c == ':' && !inQuote) {
                inKey = false;
            } else if (c == ',' && !inQuote) {
                String k = key.toString().trim().replace("\"", "");
                String v = value.toString().trim().replace("\"", "");
                if (!k.isEmpty()) {
                    result.put(k, v);
                }
                key.setLength(0);
                value.setLength(0);
                inKey = true;
            } else {
                if (inKey) {
                    key.append(c);
                } else {
                    value.append(c);
                }
            }
        }
        // 末尾 kv（最后一项的结束引号可能使 inQuote 仍为 true）
        String k = key.toString().trim().replace("\"", "");
        String v = value.toString().trim().replace("\"", "");
        if (!k.isEmpty()) {
            result.put(k, v);
        }
        return result;
    }
}
