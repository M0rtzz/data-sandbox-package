/*
 * Z-06 sample model JAR —— 行级评分模型参考实现。
 *
 * 运行契约（与 data-sandbox-jar-runner / DataDevSample 一致）：
 *   java -jar model-scorer-sample-<v>.jar --input <csv> --output <csv> [--params <json>]
 *   - 读取 --input CSV（首行为表头），逐行计算 prediction，输出表头 = 输入表头 + prediction 列。
 *   - 输出行数与输入行数严格 1:1 对齐（模型指标行级对齐契约的前提）。
 *   - --params JSON 字段：
 *       featureColumn ：主特征列（必填，数值）
 *       featureColumn2：次特征列（可选，数值）
 *       weightA       ：主特征系数（默认 1.0）
 *       weightB       ：次特征系数（默认 0.0）
 *       intercept     ：截距（默认 0.0）
 *       mode          ：classify | regress（默认 classify）
 *       threshold     ：分类判定阈值（默认 0.0）：score >= threshold → 1，否则 0
 *   - 评分公式：score = intercept + weightA*x1 + weightB*x2
 *   - 参数也可经环境变量 DS_PARAMS_JSON 注入（--params 优先）。
 */
package com.example;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class ModelScorerSample {

    public static void main(String[] args) throws Exception {
        Map<String, String> opts = parseArgs(args);
        String input = opts.get("--input");
        String output = opts.get("--output");
        if (input == null || output == null) {
            System.err.println("usage: java -jar model-scorer-sample.jar --input <csv> --output <csv> [--params <json>]");
            System.exit(2);
        }
        String paramsJson = opts.get("--params");
        if (paramsJson == null || paramsJson.isBlank()) {
            paramsJson = System.getenv("DS_PARAMS_JSON");
        }
        Map<String, String> params = parseJson(paramsJson == null ? "{}" : paramsJson);

        String featureColumn = params.get("featureColumn");
        if (featureColumn == null || featureColumn.isBlank()) {
            throw new IllegalArgumentException("featureColumn is required");
        }
        String featureColumn2 = params.get("featureColumn2");
        double weightA = parseDouble(params.get("weightA"), 1.0);
        double weightB = parseDouble(params.get("weightB"), 0.0);
        double intercept = parseDouble(params.get("intercept"), 0.0);
        String mode = params.getOrDefault("mode", "classify");
        double threshold = parseDouble(params.get("threshold"), 0.0);

        List<String[]> table = readCsv(Path.of(input));
        if (table.isEmpty()) {
            writeCsv(Path.of(output), new String[]{"prediction"}, new ArrayList<>());
            return;
        }
        String[] header = table.get(0);
        List<String[]> data = table.subList(1, table.size());

        int featureIdx = indexOf(header, featureColumn);
        if (featureIdx < 0) {
            throw new IllegalArgumentException("featureColumn not found: " + featureColumn);
        }
        int featureIdx2 = featureColumn2 == null ? -1 : indexOf(header, featureColumn2);
        if (featureColumn2 != null && featureIdx2 < 0) {
            throw new IllegalArgumentException("featureColumn2 not found: " + featureColumn2);
        }

        String[] outHeader = new String[header.length + 1];
        System.arraycopy(header, 0, outHeader, 0, header.length);
        outHeader[header.length] = "prediction";

        List<String[]> out = new ArrayList<>(data.size());
        for (String[] row : data) {
            double x1 = parseCell(row, featureIdx);
            double x2 = featureIdx2 >= 0 ? parseCell(row, featureIdx2) : 0.0;
            double score = intercept + weightA * x1 + weightB * x2;
            String prediction;
            if ("regress".equalsIgnoreCase(mode)) {
                prediction = String.format("%.4f", score);
            } else {
                prediction = score >= threshold ? "1" : "0";
            }
            String[] outRow = new String[row.length + 1];
            System.arraycopy(row, 0, outRow, 0, row.length);
            outRow[row.length] = prediction;
            out.add(outRow);
        }
        writeCsv(Path.of(output), outHeader, out);
    }

    private static double parseCell(String[] row, int idx) {
        if (idx >= row.length || row[idx] == null || row[idx].isBlank()) {
            return 0.0;
        }
        try {
            return Double.parseDouble(row[idx].trim());
        } catch (NumberFormatException e) {
            return 0.0;
        }
    }

    private static double parseDouble(String value, double fallback) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Double.parseDouble(value.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
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
        String k = key.toString().trim().replace("\"", "");
        String v = value.toString().trim().replace("\"", "");
        if (!k.isEmpty()) {
            result.put(k, v);
        }
        return result;
    }
}
