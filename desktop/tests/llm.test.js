// Tests for llm.js: the question detector's requests and answer parsing.
import assert from "node:assert/strict";
import test from "node:test";
import { answerMessages, BOOK_CHAR_LIMIT, detectorMessages, formatContext, parseDecision, trimBook } from "../web/llm.js";

const segments = [
  { text: "Здравствуйте, класс!", speaker: "teacher", isLabelManual: true },
  { text: "Здравствуйте!", speaker: "other", isLabelManual: false },
  { text: "Так, первый вопрос.", speaker: "unknown", isLabelManual: false },
  { text: "Где происходит первое событие произведения?", speaker: "teacher", isLabelManual: false },
];

test("formatContext names the speakers", () => {
  const lines = formatContext(segments).split("\n");
  assert.equal(lines[0], "Учитель (отмечено): Здравствуйте, класс!");
  assert.equal(lines[1], "Другой: Здравствуйте!");
  assert.equal(lines[2], "Неизвестно: Так, первый вопрос.");
  assert.equal(lines[3], "Учитель: Где происходит первое событие произведения?");
});

test("detectorMessages asks about the last utterance", () => {
  const messages = detectorMessages(segments);

  assert.equal(messages.length, 2);
  assert.equal(messages[0].role, "system");
  assert.ok(messages[1].content.includes("Где происходит первое событие"));
  assert.ok(messages[1].content.endsWith("Ответь JSON."));
});

test("formatContext keeps only the requested number of lines", () => {
  const many = Array.from({ length: 10 }, (_, index) => ({ text: `реплика ${index}`, speaker: "teacher", isLabelManual: false }));
  const lines = formatContext(many, 4).split("\n");

  assert.equal(lines.length, 4);
  assert.equal(lines[3], "Учитель: реплика 9");
});

test("answerMessages attaches the book text", () => {
  const messages = answerMessages("Кто написал «Капитанскую дочку»?", segments,
    { name: "Капитанская дочка", text: "Текст повести." });

  assert.ok(messages[0].content.includes("«Капитанская дочка»"));
  assert.ok(messages[0].content.includes("Текст повести."));
  assert.ok(messages[1].content.includes("Кто написал"));
});

test("answerMessages works without a book", () => {
  const messages = answerMessages("Кто написал «Капитанскую дочку»?", segments, null);

  assert.ok(messages[0].content.includes("Текст произведения не приложен"));
});

test("answerMessages trims a very long book", () => {
  const long = "а".repeat(BOOK_CHAR_LIMIT + 5000);
  const messages = answerMessages("вопрос", segments, { name: "книга", text: long });

  assert.ok(messages[0].content.length < BOOK_CHAR_LIMIT + 5000);
  assert.equal(trimBook(long).length, BOOK_CHAR_LIMIT);
});

test("parseDecision reads the verdict", () => {
  assert.equal(parseDecision('{"question": true}'), true);
  assert.equal(parseDecision('{"question": false}'), false);
  assert.equal(parseDecision('Ответ: ```json\n{"question": true}\n```'), true);
  assert.equal(parseDecision("модель передумала: false"), false);
  assert.equal(parseDecision("не понял вопрос"), null);
  assert.equal(parseDecision(""), null);
  assert.equal(parseDecision(null), null);
});
