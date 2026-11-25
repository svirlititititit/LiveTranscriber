// Building requests for the neural part: deciding whether the teacher asked a question,
// and answering it from the attached text. Pure functions, testable without a page.

export const DETECTOR_SYSTEM = [
  "Ты — часть приложения, которое в реальном времени расшифровывает урок русской литературы.",
  "Тебе дают последние реплики урока с пометками, кто говорил (Учитель, Другой или Неизвестно).",
  "Реши, содержит ли ПОСЛЕДНЯЯ реплика вопрос или задание учителя, на которое ученик должен дать содержательный ответ по произведению или по теме урока.",
  "Вопросом считаются: прямые вопросы («Где происходит первое событие?»), скрытые вопросы («Расскажи о герое», «Назови...», «Объясни, почему...»), требования ответить («Отвечай», «Итак?», «Продолжай»), если они обращены к ученику.",
  "НЕ вопрос: приветствия и организационные фразы («Здравствуйте, садитесь», «Все прочитали?», «Так, первый вопрос»), замечания о дисциплине, похвала («Молодцы»), реплики учеников, служебные пометки вроде [музыка].",
  "Сомневаешься — отвечай false.",
  "Ответь строго одним JSON без пояснений: {\"question\": true} или {\"question\": false}.",
].join(" ");

export const ANSWER_SYSTEM = [
  "Ты помогаешь ученику на уроке русской литературы.",
  "Тебе дают вопрос учителя и, если текст произведения приложен, — сам текст.",
  "Ответь так, как ответил бы у доски хороший ученик своими словами: кратко, 2–4 предложения, сплошным разговорным текстом.",
  "Без списков, без заголовков, без markdown и без слов вроде «Ответ:» — сразу сам ответ.",
  "Опирайся на текст произведения, факты не выдумывай. Если данных не хватает, честно скажи об этом одной фразой.",
  "Пиши по-русски.",
].join(" ");

export const BOOK_CHAR_LIMIT = 400000;

/** The book text, trimmed to what fits into the model's context. */
export function trimBook(text) {
  return text.length > BOOK_CHAR_LIMIT ? text.slice(0, BOOK_CHAR_LIMIT) : text;
}

function speakerTitle(speaker, isManual) {
  if (speaker === "teacher") return isManual ? "Учитель (отмечено)" : "Учитель";
  if (speaker === "other") return isManual ? "Другой (отмечено)" : "Другой";
  return "Неизвестно";
}

/** The last `count` utterances as a plain dialogue for the model. */
export function formatContext(segments, count = 6) {
  return segments.slice(-count).map((segment) =>
    `${speakerTitle(segment.speaker, segment.isLabelManual)}: ${segment.text}`).join("\n");
}

/** Messages for deciding whether the last utterance is a teacher's question. */
export function detectorMessages(segments) {
  return [
    { role: "system", content: DETECTOR_SYSTEM },
    {
      role: "user",
      content: `Реплики урока:\n${formatContext(segments)}\n\n`
        + "Содержит ли последняя реплика вопрос или задание учителя? Ответь JSON.",
    },
  ];
}

/** Messages for answering the teacher's question. `book` is `{name, text}` or `null`. */
export function answerMessages(question, segments, book) {
  let aboutBook = "\n\nТекст произведения не приложен.";
  if (book && book.text) {
    aboutBook = `\n\nТекст произведения «${book.name || "без названия"}»:\n\n${trimBook(book.text)}`;
  }
  return [
    { role: "system", content: ANSWER_SYSTEM + aboutBook },
    {
      role: "user",
      content: `Вопрос учителя: «${question}»\n\nПоследние реплики урока:\n${formatContext(segments)}`,
    },
  ];
}

/** Reads the detector's answer: `true`, `false`, or `null` when it is not a JSON verdict. */
export function parseDecision(text) {
  const match = /"question"\s*:\s*(true|false)/i.exec(String(text || ""));
  if (match) return match[1].toLowerCase() === "true";

  // Some models wrap the JSON in prose or code fences.
  const matchLoose = /\b(true|false)\b/i.exec(String(text || "").slice(0, 200));
  return matchLoose ? matchLoose[1].toLowerCase() === "true" : null;
}
