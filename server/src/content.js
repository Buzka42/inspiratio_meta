// Personality and skill content, bundled at build time by static JSON imports
// (the Worker has no fs). Source of truth: ../../examples/illunis/content. Read-only here.
import calmGuide from "../../examples/illunis/content/personalities/calm_guide.json" with { type: "json" };
import drillSergeant from "../../examples/illunis/content/personalities/drill_sergeant_trainer.json" with { type: "json" };
import personalCoach from "../../examples/illunis/content/personalities/personal_coach.json" with { type: "json" };
import productivityAdvisor from "../../examples/illunis/content/personalities/productivity_advisor.json" with { type: "json" };
import socraticTutor from "../../examples/illunis/content/personalities/socratic_tutor.json" with { type: "json" };
import dailyPlanner from "../../examples/illunis/content/personalities/daily_planner.json" with { type: "json" };
import dreamCompanion from "../../examples/illunis/content/personalities/dream_companion.json" with { type: "json" };
import reflectiveJournal from "../../examples/illunis/content/personalities/reflective_journal_guide.json" with { type: "json" };
import habitBuilding from "../../examples/illunis/content/skills/habit_building.json" with { type: "json" };
import meditationBasics from "../../examples/illunis/content/skills/meditation_basics.json" with { type: "json" };
import windDown from "../../examples/illunis/content/skills/wind_down_routine.json" with { type: "json" };
import breathwork from "../../examples/illunis/content/skills/breathwork.json" with { type: "json" };
import motivation from "../../examples/illunis/content/skills/motivation.json" with { type: "json" };
import weightTraining from "../../examples/illunis/content/skills/weight_training.json" with { type: "json" };

const byId = (list) => new Map(list.map((x) => [x.id, Object.freeze(x)]));

const PERSONALITIES = byId([calmGuide, dailyPlanner, dreamCompanion, drillSergeant, personalCoach, productivityAdvisor, reflectiveJournal, socraticTutor]);
const SKILLS = byId([breathwork, habitBuilding, meditationBasics, motivation, weightTraining, windDown]);

const resolvePersonalityId = (id) => (PERSONALITIES.has(id) ? id : null);
const resolveSkillId = (id) => (SKILLS.has(id) ? id : null);

export const getPersonality = (id) => PERSONALITIES.get(resolvePersonalityId(id)) ?? null;
export const getSkill = (id) => SKILLS.get(resolveSkillId(id)) ?? null;

export const listPersonalities = () => [...PERSONALITIES.values()].map(({ id, name }) => ({ id, name }));
export const listSkills = () => [...SKILLS.values()].map(({ id, name }) => ({ id, name }));
