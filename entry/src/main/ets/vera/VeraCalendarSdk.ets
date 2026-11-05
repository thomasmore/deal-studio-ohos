import { calendarManager } from '@kit.CalendarKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { AbilityContext } from './VeraPermissions'

export class CalendarSdkContract {
  params: string
  returnType: string
  description: string
  /** A complete sdk.call for the common case, copied into the tool result as `call`. */
  call: string

  constructor(params: string, returnType: string, description: string, call: string = '') {
    this.params = params
    this.returnType = returnType
    this.description = description
    this.call = call
  }
}

const MANAGER_TOKEN: string = 'vera-calendar-manager'
const PREFIX: string = 'CalendarKit.'
export const calendarSdkTargets: string[] = [
  PREFIX + 'calendarManager.getCalendarManager',
  PREFIX + 'CalendarManager.getCalendar',
  PREFIX + 'CalendarManager.createCalendar',
  PREFIX + 'CalendarManager.deleteCalendar',
  PREFIX + 'CalendarManager.getAllCalendars',
  PREFIX + 'CalendarManager.editEvent',
  PREFIX + 'Calendar.addEvent',
  PREFIX + 'Calendar.addEvents',
  PREFIX + 'Calendar.deleteEvent',
  PREFIX + 'Calendar.deleteEvents',
  PREFIX + 'Calendar.updateEvent',
  PREFIX + 'Calendar.getEvents',
  PREFIX + 'Calendar.queryEventInstances',
  PREFIX + 'Calendar.getConfig',
  PREFIX + 'Calendar.setConfig',
  PREFIX + 'Calendar.getAccount',
  PREFIX + 'Calendar.openEventEditPage',
  PREFIX + 'EventFilter.filterById',
  PREFIX + 'EventFilter.filterByTime',
  PREFIX + 'EventFilter.filterByTitle'
]

const EVENT_PARAMS: string = 'title?: string, date?: YYYY-MM-DD, hour?: 0-23, minute?: 0-59, durationMinutes?: positive integer (default 60), startTime?: epoch milliseconds string, endTime?: epoch milliseconds string, description?: string, timeZone?: string, isAllDay?: true|false, identifier?: string, location?: string, remindBefore?: integer minutes, repeat?: once|none|daily|weekly|monthly|yearly, event?: JSON Event wire'
const EVENT_WIRE: string = 'JSON is opaque to VERA (no JSON parser). All IDs/calendarIds must be positive int32 (1..2147483647). Native void completion becomes ok, not verified persistence. Event wire uses decimal strings for id/startTime/endTime/instanceStartTime/instanceEndTime; numeric type 0|1, boolean isAllDay/isLunar, string title/description/timeZone/identifier, location {location?:string,longitude?:number,latitude?:number}, reminderTime integer array, recurrenceRule {recurrenceFrequency:0|1|2|3 (yearly/monthly/weekly/daily),expire?:epoch string,count?:nonnegative integer,interval?:nonnegative integer,excludedDates?:epoch string array,daysOfWeek?:1-7 array,daysOfMonth?:1-31 array,daysOfYear?:1-366 array,weeksOfMonth?:1-5 array,weeksOfYear?:1-53 array,monthsOfYear?:1-12 array}. Input rejects attendee/service and instance fields; id is update-only. Read DTOs also expose attendee/service. Unsupported JSON fields are errors. JSON event cannot be mixed with flat event fields. Local dates use host time zone; timeZone is event metadata, not a date conversion zone. '
// The JSON event schema is long and the flat fields cover what a generated app
// needs, so single-event contracts point at it instead of repeating it.
const EVENT_WIRE_POINTER: string = 'Use the flat fields; the event JSON wire (schema in Calendar.addEvents) cannot be mixed with them. Local dates use the host time zone. '
const CALENDAR_SELECTION: string = 'calendarId?: positive int32 decimal (1..2147483647) string'
const MANAGER_SELECTION: string = 'manager?: vera-calendar-manager'
const EVENT_KEYS: string[] = ['id', 'type', 'title', 'location', 'startTime', 'endTime', 'isAllDay', 'attendee', 'timeZone', 'reminderTime', 'recurrenceRule', 'description', 'service', 'identifier', 'isLunar', 'instanceStartTime', 'instanceEndTime']
type CalendarEventKey = 'id' | 'type' | 'title' | 'location' | 'startTime' | 'endTime' | 'isAllDay' | 'attendee' | 'timeZone' | 'reminderTime' | 'recurrenceRule' | 'description' | 'service' | 'identifier' | 'isLunar' | 'instanceStartTime' | 'instanceEndTime'

export function calendarSdkContract(target: string): CalendarSdkContract | undefined {
  if (calendarSdkTargets.indexOf(target) < 0) { return undefined }
  switch (target) {
    case PREFIX + 'calendarManager.getCalendarManager':
      return new CalendarSdkContract('', 'string', 'Returns constant token vera-calendar-manager, usable as optional manager on CalendarManager methods. Native context comes from the host; no new permissions are requested.')
    case PREFIX + 'CalendarManager.getCalendar':
      return new CalendarSdkContract(MANAGER_SELECTION + ', ' + CALENDAR_SELECTION + ', name?: string, type?: local|email|birthday|caldav|subscribed', 'string', 'Returns decimal calendar ID. Default when no selector; account name selects a persisted native calendar (type defaults local); calendarId is mutually exclusive with name/type.')
    case PREFIX + 'CalendarManager.createCalendar':
      return new CalendarSdkContract(MANAGER_SELECTION + ', name: string, type?: local|email|birthday|caldav|subscribed, displayName?: string', 'string', 'Creates a persistent native calendar and returns decimal ID; does not change the default selection.')
    case PREFIX + 'CalendarManager.deleteCalendar':
      return new CalendarSdkContract(MANAGER_SELECTION + ', calendarId: positive int32 decimal (1..2147483647) string, confirm: true', 'string', 'Deletes only an explicitly selected non-default calendar; returns ok. Default deletion is refused.')
    case PREFIX + 'CalendarManager.getAllCalendars':
      return new CalendarSdkContract(MANAGER_SELECTION, 'string', 'Returns opaque JSON [{id:string,account:{name:string,type:string,displayName?:string}}]; VERA has no JSON parser.')
    case PREFIX + 'CalendarManager.editEvent':
      return new CalendarSdkContract(MANAGER_SELECTION + ', ' + EVENT_PARAMS, 'string', EVENT_WIRE_POINTER + 'Opens native event creation: positive int32 decimal (1..2147483647) ID, cancelled for negative result, error for zero/undefined. No whole-calendar permissions are requested.')
    case PREFIX + 'Calendar.addEvent':
      return new CalendarSdkContract(CALENDAR_SELECTION + ', ' + EVENT_PARAMS, 'string', 'Adds one event to the default calendar; the answer is its decimal event ID, which deleteEvent/deleteEvents take, so keep it in state. Give either date (YYYY-MM-DD, default today) with hour and minute, or startTime and endTime together as whole epoch milliseconds, e.g. ui.numberToString(startMs). remindBefore is minutes before the start. ' + EVENT_WIRE_POINTER + 'No ID allowed on creation.',
        'sdk.call("CalendarKit.Calendar.addEvent", ["title", "Dentist", "startTime", ui.numberToString(startMs), "endTime", ui.numberToString(endMs), "location", "12 Main Street", "remindBefore", "15"], "onEventAdded")')
    case PREFIX + 'Calendar.addEvents':
      return new CalendarSdkContract(CALENDAR_SELECTION + ', events: JSON Event wire array', 'string', EVENT_WIRE + 'Validates the entire nonempty array before writing; native void becomes ok, not IDs.')
    case PREFIX + 'Calendar.updateEvent':
      return new CalendarSdkContract(CALENDAR_SELECTION + ', id: positive int32 decimal (1..2147483647) string, ' + EVENT_PARAMS, 'string', EVENT_WIRE_POINTER + 'Fetches existing event by ID and merges supplied fields, preserving absent fields; validates the merged event. JSON event may be a patch with matching id. Location members merge with existing coordinates. Duration-only preserves exact startTime. Existing empty/absent titles are preserved; supplied titles must be nonempty. Native nonrecurring sentinel and empty recurrence arrays are normalized. Clearing a persisted recurrence with repeat once/none is unsupported and rejected. Returns ok for native void completion, not a persistence guarantee.')
    case PREFIX + 'Calendar.deleteEvent':
    case PREFIX + 'Calendar.openEventEditPage':
      return new CalendarSdkContract(CALENDAR_SELECTION + ', id: positive int32 decimal (1..2147483647) string', 'string', 'Takes the ID addEvent answered with. Returns ok; native errors retain their codes. openEventEditPage requires API 26 and reports an explicit unsupported error if the function is absent.',
        'sdk.call("' + target + '", ["id", item.eventId], "onAnswer")')
    case PREFIX + 'Calendar.deleteEvents':
      return new CalendarSdkContract(CALENDAR_SELECTION + ', ids: comma-separated positive int32 decimal (1..2147483647) IDs', 'string', 'Deletes the events whose IDs addEvent answered with -- the way to remove every event this app added -- and returns ok; malformed or empty IDs are errors, so skip the call when there are none.',
        'sdk.call("CalendarKit.Calendar.deleteEvents", ["ids", "12,15,31"], "onEventsDeleted")')
    case PREFIX + 'Calendar.getEvents':
      return new CalendarSdkContract(CALENDAR_SELECTION + ', ids?: comma-separated IDs, title?: string, start?: epoch string, end?: epoch string, eventFilter?: JSON descriptor, eventKey?: comma-separated Event keys, format?: json', 'string', EVENT_WIRE + 'Returns opaque JSON Event DTO array; choose only one of ids/title/start+end/eventFilter. Descriptor schema {kind:"id",ids:string[]} or {kind:"title",title:string} or {kind:"time",start:string,end:string}. eventKey: ' + EVENT_KEYS.join(',') + '.')
    case PREFIX + 'Calendar.queryEventInstances':
      return new CalendarSdkContract(CALENDAR_SELECTION + ', start: epoch string, end: epoch string, ids?: comma-separated IDs, eventKey?: comma-separated Event keys, format?: json', 'string', EVENT_WIRE + 'Returns opaque JSON Event DTO array including instance times when native returns them. start < end; optional IDs limit query. eventKey: ' + EVENT_KEYS.join(',') + '.')
    case PREFIX + 'Calendar.getConfig':
      return new CalendarSdkContract(CALENDAR_SELECTION, 'string', 'Returns opaque JSON {enableReminder?:boolean,color?:number|string}; VERA has no JSON parser.')
    case PREFIX + 'Calendar.setConfig':
      return new CalendarSdkContract(CALENDAR_SELECTION + ', enableReminder?: true|false, color?: decimal ARGB integer|#RRGGBB|#AARRGGBB, config?: JSON {enableReminder?:boolean,color?:number|string}', 'string', 'Reads and merges config to preserve absent fields. JSON config and flat fields are mutually exclusive; at least one field required. Returns ok.')
    case PREFIX + 'Calendar.getAccount':
      return new CalendarSdkContract(CALENDAR_SELECTION, 'string', 'Returns opaque JSON {name:string,type:string,displayName?:string}; VERA has no JSON parser.')
    case PREFIX + 'EventFilter.filterById':
      return new CalendarSdkContract('ids: comma-separated positive int32 decimal (1..2147483647) IDs', 'string', 'Returns immutable JSON descriptor {kind:"id",ids:string[]} accepted as eventFilter by getEvents, not an ok placeholder or native handle.')
    case PREFIX + 'EventFilter.filterByTime':
      return new CalendarSdkContract('start: epoch milliseconds string, end: epoch milliseconds string', 'string', 'Returns immutable JSON descriptor {kind:"time",start:string,end:string} accepted as eventFilter by getEvents; start < end.')
    default:
      return new CalendarSdkContract('title: string', 'string', 'Returns immutable JSON descriptor {kind:"title",title:string} accepted as eventFilter by getEvents for native fuzzy matching.')
  }
}

function text(value: string | undefined, name: string, required: boolean = false, max: number = 5000): string | undefined {
  if (value === undefined && !required) { return undefined }
  if (typeof value !== 'string' || value.length > max || (required && value.trim().length === 0)) {
    throw new Error(name + ' must be ' + (required ? 'a nonempty' : 'a') + ' string of at most ' + max.toString() + ' characters')
  }
  return value
}

function integer(value: string | undefined, name: string, min: number = 0, max: number = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== 'string' || !/^-?[0-9]+$/.test(value)) { throw new Error(name + ' must be a full decimal integer string') }
  let n = Number(value)
  if (!Number.isSafeInteger(n) || n < min || n > max) { throw new Error(name + ' is outside the allowed integer range') }
  return n
}

function numeric(value: number, name: string, min: number = 0, max: number = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < min || value > max) { throw new Error(name + ' must be an integer in the allowed range') }
  return value
}

function idValue(value: string | undefined, name: string = 'id'): number {
  return integer(value, name, 1, 2147483647)
}

function nativeId(value: number, name: string = 'id'): string {
  return numeric(value, name, 1, 2147483647).toString()
}

function epoch(value: string | undefined, name: string): number {
  return integer(value, name, 0, 8640000000000000)
}

function bool(value: string): boolean {
  if (value === 'true') { return true }
  if (value === 'false') { return false }
  throw new Error('boolean must be true or false')
}

function nativeBool(value: boolean): boolean {
  if (typeof value !== 'boolean') { throw new Error('JSON boolean must be true or false') }
  return value
}

function objectKeys(value: Object, allowed: string[], name: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) { throw new Error(name + ' must be a JSON object') }
  for (let key of Object.keys(value)) {
    if (allowed.indexOf(key) < 0) { throw new Error(name + ' has unsupported field ' + key) }
  }
}

function ids(value: string | undefined): number[] {
  if (typeof value !== 'string' || value.length === 0) { throw new Error('ids is required') }
  let result: number[] = []
  for (let part of value.split(',')) { result.push(idValue(part.trim())) }
  return result
}

function numericArray(value: number[] | undefined, name: string, min: number, max: number): number[] | undefined {
  if (value === undefined) { return undefined }
  if (!Array.isArray(value)) { throw new Error(name + ' must be an array') }
  let result: number[] = []
  for (let item of value) { result.push(numeric(item, name, min, max)) }
  return result
}

function epochArray(value: string[] | undefined): number[] | undefined {
  if (value === undefined) { return undefined }
  if (!Array.isArray(value)) { throw new Error('excludedDates must be an array of epoch strings') }
  let result: number[] = []
  for (let item of value) { result.push(epoch(item, 'excludedDate')) }
  return result
}

function calendarType(value: string | undefined): calendarManager.CalendarType {
  switch (value === undefined ? 'local' : value) {
    case 'local': return calendarManager.CalendarType.LOCAL
    case 'email': return calendarManager.CalendarType.EMAIL
    case 'birthday': return calendarManager.CalendarType.BIRTHDAY
    case 'caldav': return calendarManager.CalendarType.CALDAV
    case 'subscribed': return calendarManager.CalendarType.SUBSCRIBED
    default: throw new Error('type must be local, email, birthday, caldav or subscribed')
  }
}

class CalendarAccount implements calendarManager.CalendarAccount {
  readonly name: string
  type: calendarManager.CalendarType
  displayName?: string

  constructor(name: string, type: calendarManager.CalendarType, displayName?: string) {
    this.name = name
    this.type = type
    this.displayName = displayName
  }
}

class CalendarConfig implements calendarManager.CalendarConfig {
  enableReminder?: boolean
  color?: number | string

  constructor(config?: calendarManager.CalendarConfig) {
    if (config !== undefined) {
      this.enableReminder = config.enableReminder
      this.color = config.color
    }
  }
}

class CalendarLocation implements calendarManager.Location {
  location?: string
  longitude?: number
  latitude?: number

  constructor(location?: calendarManager.Location) {
    if (location !== undefined) {
      this.location = location.location
      this.longitude = location.longitude
      this.latitude = location.latitude
    }
  }
}

class CalendarRecurrence implements calendarManager.RecurrenceRule {
  recurrenceFrequency: calendarManager.RecurrenceFrequency
  expire?: number
  count?: number
  interval?: number
  excludedDates?: number[]
  daysOfWeek?: number[]
  daysOfMonth?: number[]
  daysOfYear?: number[]
  weeksOfMonth?: number[]
  weeksOfYear?: number[]
  monthsOfYear?: number[]

  constructor(frequency: calendarManager.RecurrenceFrequency) { this.recurrenceFrequency = frequency }
}

class RecurrenceWire {
  recurrenceFrequency: number = 0
  expire?: string
  count?: number
  interval?: number
  excludedDates?: string[]
  daysOfWeek?: number[]
  daysOfMonth?: number[]
  daysOfYear?: number[]
  weeksOfMonth?: number[]
  weeksOfYear?: number[]
  monthsOfYear?: number[]

  constructor(rule?: calendarManager.RecurrenceRule) {
    if (rule !== undefined) {
      this.recurrenceFrequency = rule.recurrenceFrequency
      this.expire = rule.expire?.toString()
      this.count = rule.count
      this.interval = rule.interval
      this.excludedDates = rule.excludedDates?.map((n: number): string => n.toString())
      this.daysOfWeek = rule.daysOfWeek
      this.daysOfMonth = rule.daysOfMonth
      this.daysOfYear = rule.daysOfYear
      this.weeksOfMonth = rule.weeksOfMonth
      this.weeksOfYear = rule.weeksOfYear
      this.monthsOfYear = rule.monthsOfYear
    }
  }
}

function normalizeNativeRecurrence(rule?: calendarManager.RecurrenceRule): calendarManager.RecurrenceRule | undefined {
  if (rule === undefined || (rule.recurrenceFrequency as number) === -1) { return undefined }
  if (rule.weeksOfMonth?.length !== 0 && rule.monthsOfYear?.length !== 0) { return rule }
  let wire = new RecurrenceWire(rule)
  if (wire.weeksOfMonth?.length === 0) { wire.weeksOfMonth = undefined }
  if (wire.monthsOfYear?.length === 0) { wire.monthsOfYear = undefined }
  return recurrence(wire)
}

class CalendarEvent implements calendarManager.Event {
  id?: number
  type: calendarManager.EventType = calendarManager.EventType.NORMAL
  title?: string
  startTime: number = 0
  endTime: number = 0
  isAllDay?: boolean
  description?: string
  timeZone?: string
  identifier?: string
  isLunar?: boolean
  location?: calendarManager.Location
  reminderTime?: number[]
  recurrenceRule?: calendarManager.RecurrenceRule
  attendee?: calendarManager.Attendee[]
  service?: calendarManager.EventService
  instanceStartTime?: number
  instanceEndTime?: number

  constructor(event?: calendarManager.Event) {
    if (event !== undefined) {
      this.id = event.id
      this.type = event.type
      this.title = event.title
      this.startTime = event.startTime
      this.endTime = event.endTime
      this.isAllDay = event.isAllDay
      this.description = event.description
      this.timeZone = event.timeZone
      this.identifier = event.identifier
      this.isLunar = event.isLunar
      this.location = event.location
      this.reminderTime = event.reminderTime
      this.recurrenceRule = normalizeNativeRecurrence(event.recurrenceRule)
      this.attendee = event.attendee
      this.service = event.service
      this.instanceStartTime = event.instanceStartTime
      this.instanceEndTime = event.instanceEndTime
    }
  }
}

class CalendarAttendee implements calendarManager.Attendee {
  name: string
  email: string
  role?: calendarManager.AttendeeRole
  type?: calendarManager.AttendeeType
  status?: calendarManager.AttendeeStatus

  constructor(attendee: calendarManager.Attendee) {
    this.name = attendee.name
    this.email = attendee.email
    this.role = attendee.role
    this.type = attendee.type
    this.status = attendee.status
  }
}

class CalendarService implements calendarManager.EventService {
  type: calendarManager.ServiceType
  uri: string
  description?: string

  constructor(service: calendarManager.EventService) {
    this.type = service.type
    this.uri = service.uri
    this.description = service.description
  }
}

class EventWire {
  id?: string
  type?: number
  title?: string
  startTime?: string
  endTime?: string
  isAllDay?: boolean
  description?: string
  timeZone?: string
  identifier?: string
  isLunar?: boolean
  location?: CalendarLocation
  reminderTime?: number[]
  recurrenceRule?: RecurrenceWire
  attendee?: CalendarAttendee[]
  service?: CalendarService
  instanceStartTime?: string
  instanceEndTime?: string

  constructor(event?: calendarManager.Event) {
    if (event !== undefined) {
      this.id = event.id === undefined ? undefined : nativeId(event.id)
      this.type = event.type
      this.title = event.title
      this.startTime = event.startTime?.toString()
      this.endTime = event.endTime?.toString()
      this.isAllDay = event.isAllDay
      this.description = event.description
      this.timeZone = event.timeZone
      this.identifier = event.identifier
      this.isLunar = event.isLunar
      this.location = event.location === undefined ? undefined : new CalendarLocation(event.location)
      this.reminderTime = event.reminderTime
      let rule = normalizeNativeRecurrence(event.recurrenceRule)
      this.recurrenceRule = rule === undefined ? undefined : new RecurrenceWire(rule)
      this.attendee = event.attendee?.map((a: calendarManager.Attendee): CalendarAttendee => new CalendarAttendee(a))
      this.service = event.service === undefined ? undefined : new CalendarService(event.service)
      this.instanceStartTime = event.instanceStartTime?.toString()
      this.instanceEndTime = event.instanceEndTime?.toString()
    }
  }
}

function projectEvent(event: calendarManager.Event, keys?: CalendarEventKey[]): EventWire {
  let full = new EventWire(event)
  if (keys === undefined) { return full }
  let result = new EventWire()
  for (let key of keys) {
    switch (key) {
      case 'id': result.id = full.id; break
      case 'type': result.type = full.type; break
      case 'title': result.title = full.title; break
      case 'startTime': result.startTime = full.startTime; break
      case 'endTime': result.endTime = full.endTime; break
      case 'isAllDay': result.isAllDay = full.isAllDay; break
      case 'description': result.description = full.description; break
      case 'timeZone': result.timeZone = full.timeZone; break
      case 'identifier': result.identifier = full.identifier; break
      case 'isLunar': result.isLunar = full.isLunar; break
      case 'location': result.location = full.location; break
      case 'reminderTime': result.reminderTime = full.reminderTime; break
      case 'recurrenceRule': result.recurrenceRule = full.recurrenceRule; break
      case 'attendee': result.attendee = full.attendee; break
      case 'service': result.service = full.service; break
      case 'instanceStartTime': result.instanceStartTime = full.instanceStartTime; break
      case 'instanceEndTime': result.instanceEndTime = full.instanceEndTime; break
    }
  }
  return result
}

class CalendarSummary {
  id: string
  account: CalendarAccount

  constructor(calendar: calendarManager.Calendar) {
    this.id = nativeId(calendar.id, 'calendarId')
    let account = calendar.getAccount()
    this.account = new CalendarAccount(account.name, account.type, account.displayName)
  }
}

function recurrence(value: RecurrenceWire): CalendarRecurrence {
  objectKeys(value, ['recurrenceFrequency', 'expire', 'count', 'interval', 'excludedDates', 'daysOfWeek', 'daysOfMonth', 'daysOfYear', 'weeksOfMonth', 'weeksOfYear', 'monthsOfYear'], 'recurrenceRule')
  let rule = new CalendarRecurrence(numeric(value.recurrenceFrequency, 'recurrenceFrequency', 0, 3) as calendarManager.RecurrenceFrequency)
  if (value.expire !== undefined) { rule.expire = epoch(value.expire, 'expire') }
  if (value.count !== undefined) { rule.count = numeric(value.count, 'count') }
  if (value.interval !== undefined) { rule.interval = numeric(value.interval, 'interval') }
  rule.excludedDates = epochArray(value.excludedDates)
  rule.daysOfWeek = numericArray(value.daysOfWeek, 'daysOfWeek', 1, 7)
  rule.daysOfMonth = numericArray(value.daysOfMonth, 'daysOfMonth', 1, 31)
  rule.daysOfYear = numericArray(value.daysOfYear, 'daysOfYear', 1, 366)
  rule.weeksOfMonth = numericArray(value.weeksOfMonth, 'weeksOfMonth', 1, 5)
  rule.weeksOfYear = numericArray(value.weeksOfYear, 'weeksOfYear', 1, 53)
  rule.monthsOfYear = numericArray(value.monthsOfYear, 'monthsOfYear', 1, 12)
  if (rule.weeksOfMonth !== undefined && rule.daysOfWeek !== undefined && rule.weeksOfMonth.length !== rule.daysOfWeek.length) { throw new Error('weeksOfMonth and daysOfWeek must have matching lengths') }
  if (rule.monthsOfYear !== undefined && rule.daysOfMonth !== undefined && rule.monthsOfYear.length !== rule.daysOfMonth.length) { throw new Error('monthsOfYear and daysOfMonth must have matching lengths') }
  return rule
}

function eventLocation(value: CalendarLocation, base?: calendarManager.Location): CalendarLocation {
  objectKeys(value, ['location', 'longitude', 'latitude'], 'location')
  let result = new CalendarLocation(base)
  if (value.location !== undefined) { result.location = text(value.location, 'location') }
  if (value.longitude !== undefined) {
    if (typeof value.longitude !== 'number' || !Number.isFinite(value.longitude) || value.longitude < -180 || value.longitude > 180) { throw new Error('longitude must be between -180 and 180') }
    result.longitude = value.longitude
  }
  if (value.latitude !== undefined) {
    if (typeof value.latitude !== 'number' || !Number.isFinite(value.latitude) || value.latitude < -90 || value.latitude > 90) { throw new Error('latitude must be between -90 and 90') }
    result.latitude = value.latitude
  }
  return result
}

function mergeWire(value: EventWire, base?: calendarManager.Event): CalendarEvent {
  objectKeys(value, ['id', 'type', 'title', 'startTime', 'endTime', 'isAllDay', 'description', 'timeZone', 'identifier', 'isLunar', 'location', 'reminderTime', 'recurrenceRule'], 'event')
  let event = new CalendarEvent(base)
  if (value.id !== undefined) {
    let id = idValue(value.id)
    if (base === undefined || id !== base.id) { throw new Error('event id is update-only and must match id') }
  }
  if (value.type !== undefined) { event.type = numeric(value.type, 'type', 0, 1) as calendarManager.EventType }
  if (value.title !== undefined) { event.title = text(value.title, 'title', true) }
  if (value.startTime !== undefined) { event.startTime = epoch(value.startTime, 'startTime') }
  if (value.endTime !== undefined) { event.endTime = epoch(value.endTime, 'endTime') }
  if (base === undefined && (value.startTime === undefined || value.endTime === undefined)) { throw new Error('event requires startTime and endTime epoch strings') }
  if (value.description !== undefined) { event.description = text(value.description, 'description') }
  if (value.timeZone !== undefined) { event.timeZone = text(value.timeZone, 'timeZone') }
  if (value.identifier !== undefined) { event.identifier = text(value.identifier, 'identifier') }
  if (value.isAllDay !== undefined) { event.isAllDay = nativeBool(value.isAllDay) }
  if (value.isLunar !== undefined) { event.isLunar = nativeBool(value.isLunar) }
  if (value.location !== undefined) { event.location = eventLocation(value.location, event.location) }
  if (value.reminderTime !== undefined) { event.reminderTime = numericArray(value.reminderTime, 'reminderTime', -Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER) }
  if (value.recurrenceRule !== undefined) { event.recurrenceRule = recurrence(value.recurrenceRule) }
  validateEvent(event, base === undefined)
  return event
}

function validateEvent(event: CalendarEvent, creating: boolean): void {
  text(event.title, 'title', creating)
  if (event.id !== undefined) { nativeId(event.id) }
  numeric(event.type, 'type', 0, 1)
  numeric(event.startTime, 'startTime', 0, 8640000000000000)
  numeric(event.endTime, 'endTime', 0, 8640000000000000)
  if (event.endTime <= event.startTime) { throw new Error('endTime must be after startTime') }
  text(event.description, 'description')
  text(event.timeZone, 'timeZone')
  text(event.identifier, 'identifier')
  if (event.isAllDay !== undefined) { nativeBool(event.isAllDay) }
  if (event.isLunar !== undefined) { nativeBool(event.isLunar) }
  if (event.location !== undefined) { eventLocation(new CalendarLocation(event.location)) }
  numericArray(event.reminderTime, 'reminderTime', -Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER)
  if (event.recurrenceRule !== undefined) { recurrence(new RecurrenceWire(event.recurrenceRule)) }
}

const FLAT_EVENT_FIELDS: string[] = ['title', 'date', 'hour', 'minute', 'durationMinutes', 'startTime', 'endTime', 'description', 'timeZone', 'isAllDay', 'identifier', 'location', 'remindBefore', 'repeat']

function hasFields(params: Map<string, string>, fields: string[]): boolean {
  for (let field of fields) { if (params.has(field)) { return true } }
  return false
}

function localStart(params: Map<string, string>, base?: calendarManager.Event): number {
  let date = new Date(base === undefined ? Date.now() : base.startTime)
  date.setHours(12, 0, 0, 0)
  let dateText = params.get('date')
  if (dateText !== undefined) {
    if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(dateText)) { throw new Error('date must be YYYY-MM-DD') }
    let parts = dateText.split('-')
    let year = integer(parts[0], 'year', 1, 9999)
    let month = integer(parts[1], 'month', 1, 12)
    let day = integer(parts[2], 'day', 1, 31)
    date.setFullYear(year, month - 1, day)
    if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) { throw new Error('date does not exist') }
  }
  let original = new Date(base === undefined ? date.getTime() : base.startTime)
  let hour = params.has('hour') ? integer(params.get('hour'), 'hour', 0, 23) : base === undefined ? -1 : original.getHours()
  let minute = params.has('minute') ? integer(params.get('minute'), 'minute', 0, 59) : base === undefined ? -1 : original.getMinutes()
  if (hour < 0 || minute < 0) { throw new Error('hour and minute are required for local event creation') }
  let expectedYear = date.getFullYear()
  let expectedMonth = date.getMonth()
  let expectedDay = date.getDate()
  date.setHours(hour, minute, 0, 0)
  if (date.getFullYear() !== expectedYear || date.getMonth() !== expectedMonth || date.getDate() !== expectedDay || date.getHours() !== hour || date.getMinutes() !== minute) { throw new Error('local time does not exist (DST transition)') }
  return date.getTime()
}

function repeatRule(value: string): CalendarRecurrence | undefined {
  switch (value.trim().toLowerCase()) {
    case '':
    case 'once':
    case 'none': return undefined
    case 'daily': return new CalendarRecurrence(calendarManager.RecurrenceFrequency.DAILY)
    case 'weekly': return new CalendarRecurrence(calendarManager.RecurrenceFrequency.WEEKLY)
    case 'monthly': return new CalendarRecurrence(calendarManager.RecurrenceFrequency.MONTHLY)
    case 'yearly': return new CalendarRecurrence(calendarManager.RecurrenceFrequency.YEARLY)
    default: throw new Error('repeat must be once, none, daily, weekly, monthly or yearly')
  }
}

function eventInput(params: Map<string, string>, base?: calendarManager.Event): CalendarEvent {
  let json = params.get('event')
  if (json !== undefined) {
    if (hasFields(params, FLAT_EVENT_FIELDS)) { throw new Error('event JSON conflicts with flat event fields') }
    return mergeWire(JSON.parse(json) as EventWire, base)
  }
  let event = new CalendarEvent(base)
  if (params.has('title')) { event.title = text(params.get('title'), 'title', true) }
  let epochFields = hasFields(params, ['startTime', 'endTime'])
  let localFields = hasFields(params, ['date', 'hour', 'minute', 'durationMinutes'])
  if (epochFields && localFields) { throw new Error('epoch fields conflict with local date/hour/minute/durationMinutes') }
  if (epochFields) {
    if (base === undefined && (!params.has('startTime') || !params.has('endTime'))) { throw new Error('startTime and endTime are required together') }
    if (params.has('startTime')) { event.startTime = epoch(params.get('startTime'), 'startTime') }
    if (params.has('endTime')) { event.endTime = epoch(params.get('endTime'), 'endTime') }
  } else if (base === undefined || localFields) {
    event.startTime = base !== undefined && !hasFields(params, ['date', 'hour', 'minute']) ? base.startTime : localStart(params, base)
    let duration = params.has('durationMinutes') ? integer(params.get('durationMinutes'), 'durationMinutes', 1) * 60000 : base === undefined ? 3600000 : base.endTime - base.startTime
    event.endTime = event.startTime + duration
  }
  if (params.has('description')) { event.description = text(params.get('description'), 'description') }
  if (params.has('timeZone')) { event.timeZone = text(params.get('timeZone'), 'timeZone') }
  if (params.has('identifier')) { event.identifier = text(params.get('identifier'), 'identifier') }
  if (params.has('isAllDay')) { event.isAllDay = bool(params.get('isAllDay')!) }
  if (params.has('location')) {
    let location = new CalendarLocation(event.location)
    location.location = text(params.get('location'), 'location')
    event.location = location
  }
  if (params.has('remindBefore')) {
    let reminder = integer(params.get('remindBefore'), 'remindBefore', -Number.MAX_SAFE_INTEGER)
    event.reminderTime = reminder < 0 ? undefined : [reminder]
  }
  if (params.has('repeat')) {
    let rule = repeatRule(params.get('repeat')!)
    if (rule === undefined && event.recurrenceRule !== undefined) { throw new Error('clearing existing recurrence is unsupported; repeat once/none cannot remove a persisted rule') }
    event.recurrenceRule = rule
  }
  validateEvent(event, base === undefined)
  return event
}

class FilterDescriptor {
  kind: string
  ids?: string[]
  title?: string
  start?: string
  end?: string

  constructor(kind: string) { this.kind = kind }
}

function timeRange(start: string | undefined, end: string | undefined): number[] {
  let a = epoch(start, 'start')
  let b = epoch(end, 'end')
  if (b <= a) { throw new Error('end must be after start') }
  return [a, b]
}

function filterDescriptor(params: Map<string, string>, kind?: string): FilterDescriptor | undefined {
  if (params.has('eventFilter')) {
    if (kind !== undefined || hasFields(params, ['ids', 'title', 'start', 'end'])) { throw new Error('eventFilter conflicts with flat filter selectors') }
    let descriptor = JSON.parse(params.get('eventFilter')!) as FilterDescriptor
    objectKeys(descriptor, ['kind', 'ids', 'title', 'start', 'end'], 'eventFilter')
    return descriptor
  }
  let count = (params.has('ids') ? 1 : 0) + (params.has('title') ? 1 : 0) + (hasFields(params, ['start', 'end']) ? 1 : 0)
  if (count > 1) { throw new Error('conflicting filter selectors') }
  let selected = kind === undefined ? params.has('ids') ? 'id' : params.has('title') ? 'title' : hasFields(params, ['start', 'end']) ? 'time' : undefined : kind
  if (selected === undefined) { return undefined }
  let descriptor = new FilterDescriptor(selected)
  if (selected === 'id') { descriptor.ids = ids(params.get('ids')).map((n: number): string => n.toString()) }
  if (selected === 'title') { descriptor.title = text(params.get('title'), 'title', true) }
  if (selected === 'time') {
    let range = timeRange(params.get('start'), params.get('end'))
    descriptor.start = range[0].toString()
    descriptor.end = range[1].toString()
  }
  return descriptor
}

function nativeFilter(descriptor: FilterDescriptor): calendarManager.EventFilter {
  objectKeys(descriptor, ['kind', 'ids', 'title', 'start', 'end'], 'eventFilter')
  switch (descriptor.kind) {
    case 'id': {
      if (descriptor.title !== undefined || descriptor.start !== undefined || descriptor.end !== undefined || !Array.isArray(descriptor.ids) || descriptor.ids.length === 0) { throw new Error('invalid id eventFilter descriptor') }
      let values: number[] = []
      for (let id of descriptor.ids) { values.push(idValue(id)) }
      return calendarManager.EventFilter.filterById(values)
    }
    case 'title':
      if (descriptor.ids !== undefined || descriptor.start !== undefined || descriptor.end !== undefined) { throw new Error('invalid title eventFilter descriptor') }
      return calendarManager.EventFilter.filterByTitle(text(descriptor.title, 'title', true)!)
    case 'time': {
      if (descriptor.ids !== undefined || descriptor.title !== undefined) { throw new Error('invalid time eventFilter descriptor') }
      let range = timeRange(descriptor.start, descriptor.end)
      return calendarManager.EventFilter.filterByTime(range[0], range[1])
    }
    default: throw new Error('unsupported eventFilter kind')
  }
}

function eventKeys(params: Map<string, string>): CalendarEventKey[] | undefined {
  let format = params.get('format')
  if (format !== undefined && format !== 'json') { throw new Error('format must be json') }
  let value = params.get('eventKey')
  if (value === undefined) { return undefined }
  let keys: CalendarEventKey[] = []
  for (let part of value.split(',')) {
    let key = part.trim()
    if (EVENT_KEYS.indexOf(key) < 0) { throw new Error('unsupported eventKey ' + key) }
    keys.push(key as CalendarEventKey)
  }
  return keys
}

function managerFor(params: Map<string, string>): calendarManager.CalendarManager {
  let token = params.get('manager')
  if (token !== undefined && token !== MANAGER_TOKEN) { throw new Error('invalid manager token; use vera-calendar-manager') }
  let context = AbilityContext.value
  if (context === null) { throw new Error('no ability context yet') }
  return calendarManager.getCalendarManager(context)
}

async function selectedCalendar(manager: calendarManager.CalendarManager, params: Map<string, string>, accountAllowed: boolean = false): Promise<calendarManager.Calendar> {
  try {
    let idText = params.get('calendarId')
    if (idText !== undefined) {
      if (hasFields(params, ['name', 'type'])) { throw new Error('calendarId conflicts with account name/type') }
      let id = idValue(idText, 'calendarId')
      let calendars = await manager.getAllCalendars()
      for (let calendar of calendars) { if (calendar.id === id) { return calendar } }
      throw new Error('calendarId was not found among available calendars')
    }
    if (accountAllowed && hasFields(params, ['name', 'type'])) {
      let account = new CalendarAccount(text(params.get('name'), 'name', true)!, calendarType(params.get('type')))
      return await manager.getCalendar(account)
    }
    return await manager.getCalendar()
  } catch (e) {
    throw e as Error
  }
}

function color(value: number | string): number | string {
  if (typeof value === 'number') { return numeric(value, 'color', 0, 4294967295) }
  if (typeof value !== 'string') { throw new Error('color must be an ARGB integer or hex color') }
  if (/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(value)) { return value }
  return integer(value, 'color', 0, 4294967295)
}

function mergedConfig(params: Map<string, string>, current: calendarManager.CalendarConfig): CalendarConfig {
  let config = new CalendarConfig(current)
  let json = params.get('config')
  if (json !== undefined) {
    if (hasFields(params, ['enableReminder', 'color'])) { throw new Error('config JSON conflicts with flat config fields') }
    let wire = JSON.parse(json) as CalendarConfig
    objectKeys(wire, ['enableReminder', 'color'], 'config')
    if (wire.enableReminder === undefined && wire.color === undefined) { throw new Error('config must contain at least one field') }
    if (wire.enableReminder !== undefined) { config.enableReminder = nativeBool(wire.enableReminder) }
    if (wire.color !== undefined) { config.color = color(wire.color) }
  } else {
    if (!hasFields(params, ['enableReminder', 'color'])) { throw new Error('enableReminder or color is required') }
    if (params.has('enableReminder')) { config.enableReminder = bool(params.get('enableReminder')!) }
    if (params.has('color')) { config.color = color(params.get('color')!) }
  }
  if (config.enableReminder !== undefined) { nativeBool(config.enableReminder) }
  if (config.color !== undefined) { color(config.color) }
  return config
}

function validateParams(target: string, params: Map<string, string>): void {
  let allowed: string[] = []
  switch (target) {
    case PREFIX + 'calendarManager.getCalendarManager': break
    case PREFIX + 'CalendarManager.getCalendar': allowed = ['manager', 'calendarId', 'name', 'type']; break
    case PREFIX + 'CalendarManager.createCalendar': allowed = ['manager', 'name', 'type', 'displayName']; break
    case PREFIX + 'CalendarManager.deleteCalendar': allowed = ['manager', 'calendarId', 'confirm']; break
    case PREFIX + 'CalendarManager.getAllCalendars': allowed = ['manager']; break
    case PREFIX + 'CalendarManager.editEvent': allowed = ['manager', 'event'].concat(FLAT_EVENT_FIELDS); break
    case PREFIX + 'Calendar.addEvent': allowed = ['calendarId', 'event'].concat(FLAT_EVENT_FIELDS); break
    case PREFIX + 'Calendar.addEvents': allowed = ['calendarId', 'events']; break
    case PREFIX + 'Calendar.updateEvent': allowed = ['calendarId', 'id', 'event'].concat(FLAT_EVENT_FIELDS); break
    case PREFIX + 'Calendar.deleteEvent':
    case PREFIX + 'Calendar.openEventEditPage': allowed = ['calendarId', 'id']; break
    case PREFIX + 'Calendar.deleteEvents': allowed = ['calendarId', 'ids']; break
    case PREFIX + 'Calendar.getEvents': allowed = ['calendarId', 'ids', 'title', 'start', 'end', 'eventFilter', 'eventKey', 'format']; break
    case PREFIX + 'Calendar.queryEventInstances': allowed = ['calendarId', 'start', 'end', 'ids', 'eventKey', 'format']; break
    case PREFIX + 'Calendar.setConfig': allowed = ['calendarId', 'enableReminder', 'color', 'config']; break
    case PREFIX + 'Calendar.getConfig':
    case PREFIX + 'Calendar.getAccount': allowed = ['calendarId']; break
    case PREFIX + 'EventFilter.filterById': allowed = ['ids']; break
    case PREFIX + 'EventFilter.filterByTime': allowed = ['start', 'end']; break
    case PREFIX + 'EventFilter.filterByTitle': allowed = ['title']; break
    default: throw new Error('unsupported CalendarKit target ' + target)
  }
  for (let key of params.keys()) { if (allowed.indexOf(key) < 0) { throw new Error('unsupported parameter ' + key) } }
}

async function dispatchCalendar(target: string, params: Map<string, string>): Promise<string> {
  try {
    validateParams(target, params)
    if (target === PREFIX + 'EventFilter.filterById' || target === PREFIX + 'EventFilter.filterByTime' || target === PREFIX + 'EventFilter.filterByTitle') {
      let kind = target === PREFIX + 'EventFilter.filterById' ? 'id' : target === PREFIX + 'EventFilter.filterByTime' ? 'time' : 'title'
      let descriptor = filterDescriptor(params, kind)!
      nativeFilter(descriptor)
      return JSON.stringify(descriptor)
    }
    let manager = managerFor(params)
    switch (target) {
      case PREFIX + 'calendarManager.getCalendarManager': return MANAGER_TOKEN
      case PREFIX + 'CalendarManager.getCalendar': return nativeId((await selectedCalendar(manager, params, true)).id, 'calendarId')
      case PREFIX + 'CalendarManager.createCalendar': {
        let account = new CalendarAccount(text(params.get('name'), 'name', true)!, calendarType(params.get('type')), text(params.get('displayName'), 'displayName', false, 64))
        return nativeId((await manager.createCalendar(account)).id, 'created calendarId')
      }
      case PREFIX + 'CalendarManager.getAllCalendars': {
        let calendars = await manager.getAllCalendars()
        return JSON.stringify(calendars.map((c: calendarManager.Calendar): CalendarSummary => new CalendarSummary(c)))
      }
      case PREFIX + 'CalendarManager.deleteCalendar': {
        idValue(params.get('calendarId'), 'calendarId')
        if (params.get('confirm') !== 'true') { throw new Error('deleteCalendar requires confirm=true') }
        let calendar = await selectedCalendar(manager, params)
        let defaultCalendar = await manager.getCalendar()
        if (calendar.id === defaultCalendar.id) { throw new Error('refusing to delete the default calendar') }
        await manager.deleteCalendar(calendar)
        let remaining = await manager.getAllCalendars()
        let defaultFound = false
        for (let item of remaining) {
          if (item.id === calendar.id) { throw new Error('calendar deletion was not confirmed') }
          if (item.id === defaultCalendar.id) { defaultFound = true }
        }
        if (!defaultFound) { throw new Error('calendar deletion verification unavailable') }
        return 'ok'
      }
      case PREFIX + 'CalendarManager.editEvent': {
        let result = await manager.editEvent(eventInput(params))
        if (result === undefined || result === 0) { throw new Error('editEvent returned no event ID') }
        if (result < 0) { return 'cancelled' }
        return nativeId(result, 'editEvent result')
      }
    }
    let calendar = await selectedCalendar(manager, params)
    switch (target) {
      case PREFIX + 'Calendar.addEvent': return nativeId(await calendar.addEvent(eventInput(params)), 'added event id')
      case PREFIX + 'Calendar.addEvents': {
        let source = params.get('events')
        if (source === undefined) { throw new Error('events is required') }
        let wires = JSON.parse(source) as EventWire[]
        if (!Array.isArray(wires) || wires.length === 0) { throw new Error('events must be a nonempty JSON array') }
        let events: calendarManager.Event[] = []
        for (let wire of wires) { events.push(mergeWire(wire)) }
        await calendar.addEvents(events)
        return 'ok'
      }
      case PREFIX + 'Calendar.deleteEvent':
        await calendar.deleteEvent(idValue(params.get('id')))
        return 'ok'
      case PREFIX + 'Calendar.deleteEvents':
        await calendar.deleteEvents(ids(params.get('ids')))
        return 'ok'
      case PREFIX + 'Calendar.updateEvent': {
        let id = idValue(params.get('id'))
        let existing = await calendar.getEvents(calendarManager.EventFilter.filterById([id]), EVENT_KEYS as CalendarEventKey[])
        let found: calendarManager.Event | undefined = undefined
        for (let event of existing) { if (event.id === id) { found = event; break } }
        if (found === undefined) { throw new Error('event id was not found') }
        let merged = eventInput(params, found)
        await calendar.updateEvent(merged)
        return 'ok'
      }
      case PREFIX + 'Calendar.getEvents': {
        let descriptor = filterDescriptor(params)
        let filter = descriptor === undefined ? undefined : nativeFilter(descriptor)
        let keys = eventKeys(params)
        let events: calendarManager.Event[]
        if (filter === undefined) {
          events = await calendar.getEvents()
          if (keys !== undefined && events.length > 0) {
            let allIds: number[] = []
            for (let event of events) { allIds.push(idValue(event.id?.toString())) }
            events = await calendar.getEvents(calendarManager.EventFilter.filterById(allIds), keys)
          }
        }
        else if (keys === undefined) { events = await calendar.getEvents(filter) }
        else { events = await calendar.getEvents(filter, keys) }
        return JSON.stringify(events.map((e: calendarManager.Event): EventWire => projectEvent(e, keys)))
      }
      case PREFIX + 'Calendar.queryEventInstances': {
        let range = timeRange(params.get('start'), params.get('end'))
        let selectedIds = params.has('ids') ? ids(params.get('ids')) : undefined
        let keys = eventKeys(params)
        let events: calendarManager.Event[]
        if (keys !== undefined) { events = await calendar.queryEventInstances(range[0], range[1], selectedIds === undefined ? [] : selectedIds, keys) }
        else if (selectedIds !== undefined) { events = await calendar.queryEventInstances(range[0], range[1], selectedIds) }
        else { events = await calendar.queryEventInstances(range[0], range[1]) }
        return JSON.stringify(events.map((e: calendarManager.Event): EventWire => projectEvent(e, keys)))
      }
      case PREFIX + 'Calendar.getConfig': return JSON.stringify(new CalendarConfig(calendar.getConfig()))
      case PREFIX + 'Calendar.setConfig':
        await calendar.setConfig(mergedConfig(params, calendar.getConfig()))
        return 'ok'
      case PREFIX + 'Calendar.getAccount': {
        let account = calendar.getAccount()
        return JSON.stringify(new CalendarAccount(account.name, account.type, account.displayName))
      }
      case PREFIX + 'Calendar.openEventEditPage': {
        let id = idValue(params.get('id'))
        if (typeof calendar.openEventEditPage !== 'function') { throw new Error('openEventEditPage requires API 26; unavailable on this device') }
        await calendar.openEventEditPage(id)
        return 'ok'
      }
      default: throw new Error('unsupported CalendarKit target ' + target)
    }
  } catch (e) {
    let error = e as BusinessError
    return 'error: ' + (error.code === undefined ? '' : error.code.toString() + ': ') + error.message
  }
}

export async function runCalendarSdkAdapter(target: string, params: Map<string, string>): Promise<string> {
  return await dispatchCalendar(target, params)
}
