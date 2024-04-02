#!/usr/bin/env python3

""" Search the current ATA World, District and State/Province standings and print the results. """

# SPDX-License-Identifier: MIT
# pylint: disable=too-many-lines

import argparse
import glob
import html
import io
import os
import random
import re
import sys
import time
import yaml

import requests

EPILOG = "-W and -S can be used together, or separately. If neither -W nor -S are set, default to -W"
WORLDBASE = "https://atamartialarts.com/events/tournament-standings/worlds-standings/"
STATEBASE = "https://atamartialarts.com/events/tournament-standings/state-standings/"
NAME_SUFFIXES = ["jr.", "sr.", "i", "ii", "iii", "iv"]
NAME_PREFIXES = ["van", "san", "de", "da", "los", "st.", "saint"]


RANDOM_WORDS = []
USED_WORDS = []
RANDOM_NAME_MAP = {}

OMIT_CHOICES = ["location", "region", "place", "code", "division", "points"]
DISTRICTS = {
    "Northeast": ["va", "wv", "md", "pa", "de", "nj", "ny", "ct", "ri", "ma", "vt", "nh", "me", "dc"],
    "Southeast": ["tn", "nc", "sc", "ga", "fl", "al", "ms"],
    "Mid-America": ["wi", "mi", "il", "in", "oh", "ky", "oh"],
    "Midwest": ["ne", "ka", "mo"],
    "South": ["tx", "la", "ar", "ok"],
    "Southwest": ["az", "nv", "ca"],
    "Rockies": ["nm", "co", "ut", "wy", "mo"],
    "Northwest": ["id", "or", "wa", "bc", "bc", "sk", "mb"],
}

COMPETITIONS = {
    "forms": "forms",
    "weapons": "weapons",
    "combat-weapons": "combat weapons",
    "sparring": "sparring",
    "creative-forms": "creative forms",
    "creative-weapons": "creative weapons",
    "x-treme-forms": "x-treme forms",
    "x-treme-weapons": "x-treme weapons",
}

SUPPRESSED_ARGUMENTS = [
    ("-R", "--randomize-names", True),
    ("-G", "--generate-readme", True),
    ("-2", "--readme-explanation", True),
    ("-M", "--maximum-lines", True),
    ("-X", "--print-readme-heading", False),
    ("-Y", "--print-readme-trailer", False),
    ("-o", "--output", True),
]


def get_next_random_word():
    """
    Return the next random word from RANDOM_WORDS.
    Push the word onto USED_WORDS.
    If none are left in RANDOM_WORDS, reassign RANDOM_WORDS and reshuffle.
    """
    # pylint: disable=global-statement
    global RANDOM_WORDS, USED_WORDS
    if not RANDOM_WORDS:
        RANDOM_WORDS = USED_WORDS
        USED_WORDS = []
        random.shuffle(RANDOM_WORDS)
    wd = RANDOM_WORDS.pop(0)
    USED_WORDS.append(wd)
    return wd


def get_random_word(nm):
    """
    Given a name, return a random name to use in its place.
    Do this by grabbing two random words at a time from the front of the list.
    """
    # pylint: disable=global-statement
    global RANDOM_NAME_MAP
    while True:
        repl_name = get_next_random_word().capitalize() + get_next_random_word()
        if repl_name not in RANDOM_NAME_MAP:
            RANDOM_NAME_MAP[nm] = repl_name
            return repl_name


def get_random_name(args, nm):
    """
    Given a name, and randomizing is on, return a random name to use in its place.
    """
    if not args.randomize_names:
        return nm

    # pylint: disable=global-statement
    global RANDOM_WORDS, USED_WORDS, NAME_SUFFIXES
    if not RANDOM_WORDS and not USED_WORDS:
        with open(args.randomize_names) as fp:
            for l in fp:
                RANDOM_WORDS.append(l.strip().lower())
        random.shuffle(RANDOM_WORDS)
        for nms in NAME_SUFFIXES:
            RANDOM_NAME_MAP[nms] = nms
        for nmp in NAME_PREFIXES:
            RANDOM_NAME_MAP[nmp] = nmp

    newname = []
    for l in nm.lower().split():
        newname.append(get_random_word(l))
    return " ".join(newname)


def get_cache_dir():
    """Determine the directory where to store a cache of the web files"""
    for name in ["TEMP", "TMP", "TMPDIR", "TEMPDIR"]:
        dirname = os.environ.get(name)
        if dirname:
            return dirname
    return "/tmp"


def strip_html(l):
    """strip out all html <tags>"""
    l = re.sub("<[^>]*>", "", l)
    l = re.sub(r"\s+", " ", l)
    return l


def get_url(args, url):
    """
    Retrieve a URL. Exit with an error message if there is an error retrieving it.
    Return the body as an array of lines.

    Note that this uses a cache, so that each web page is visited exactly once.
    This speeds up running the program multiple times in a row.
    There are options to ignore, disable and clean the cache.
    Cache files older than 24 hours are automatically ignored.
    """

    if args.dots:
        print(".", end="", file=sys.stderr)
        sys.stderr.flush()
    urlname = re.sub("[^a-zA-Z0-9_]", "", url)
    cachename = f"{args.cache_directory}/atastandings.{urlname}"
    usefile = not args.ignore_existing_cache
    if usefile:
        try:
            if args.verbose:
                print(f"looking for {args.cache_directory}/atastandings.{urlname}")
            st = os.stat(cachename)
            if time.time() - st.st_mtime > 24 * 60 * 60:  # ignore files older than 24 hours
                if not args.ignore_cache_times:
                    os.unlink(cachename)
                    if args.verbose:
                        print(f"{cachename} is too old -- ignored")

            with open(cachename) as fp:
                text = fp.read()

        except FileNotFoundError:
            usefile = False

    if not usefile:
        if args.verbose:
            print(f"getting url={url}")
        r = requests.get(url)
        if r.status_code >= 300:
            sys.exit(f"Accessing {url} returned the status code {r.status_code}")

        if args.verbose > 2:
            print(f"page={r.text}")
        if not args.do_not_write_cache:
            if args.verbose:
                print(f"writing to {cachename}")
            with open(f"{cachename}.tmp", "w") as fp:
                fp.write(r.text)
            os.rename(f"{cachename}.tmp", f"{cachename}")
        text = r.text

    return text.splitlines()


def clean_cache(args):
    """Clear out all files in the cache directory named "atastandings." followed by anything."""
    for fname in glob.glob(f"{args.cache_directory}/atastandings.*"):
        if args.verbose:
            print(f"Cleaning {fname}")
        os.unlink(fname)


def trim_border(lines, border):
    """
    Trim all lines up through the first line that includes the string border.
    Then trim all lines after border occurs again.
    Also trim any lines after "Listed Tournaments"
    """
    nl = []
    saving = False
    for l in lines:
        if border in l:
            if saving:
                break
        elif "Listed Tournaments" in l:
            break
        if saving:
            nl.append(l)
        if border in l:
            saving = True
    return nl


def join_li_td_tr(lines):
    """Join any lines that end with </li>, </td> and </th> with the subsequent line"""
    for i in range(len(lines) - 1):
        l = lines[i].strip().replace(" ", "")
        if l.endswith("</li>") or l.endswith("</td>") or l.endswith("</th>"):
            lines[i + 1] = lines[i] + lines[i + 1]
            lines[i] = ""
    return lines


def fgrep(s, lines):
    """search for lines that have the given string and return that array"""
    newlines = []
    for l in lines:
        if s in l:
            newlines.append(l)
    return newlines


def get_code(l):
    """extract code=ABC from a line"""
    l = re.sub("^.*code=", "code=", l)
    l = re.sub('".*$', "", l)
    return l


def fix_html(s):
    """Look in a string and replace instances of &xyz; with the equivalent values"""
    return html.unescape(s)


def get_codes(args, url):
    """Retrieve a URL. Retrieve the list of codes as an array of [division-code, division-name]"""
    lines = fgrep("code=", join_li_td_tr(get_url(args, url)))
    nl = []
    for l in lines:
        nl.append([get_code(l), strip_html(l).replace("VIEW", "")])
    return nl


def print_lines(lines):
    """print the lines of an array"""
    for l in lines:
        print(l)


def get_info(args, code, region, url, border):
    """Get the standings from this url"""
    lines = get_url(args, url)
    lines = trim_border(lines, border)
    dispcode = code[0].split("=")[1]
    for i, val in enumerate(lines):
        if "text-primary" in val:
            lines[i] = f"DIVISION {dispcode} {val}"
        lines[i] = re.sub(" +", " ", lines[i])
        lines[i] = re.sub('style="[^"]*"', "", lines[i])
        lines[i] = re.sub('class="[^"]*"', "", lines[i])

    lines = join_li_td_tr(lines)

    nl = []
    for l in lines:
        l = l.replace("</td>", "").replace("</th>", "").replace("</li>", "")
        l = re.sub("<t[rd][^>]*>", " | ", l)
        l = re.sub(r"^\s+[|]\s+", " ", l)
        l = re.sub("<[^>]*>", "", l)  # eliminates ALL html tags
        l = (
            l.replace("The points below", "")
            .replace("Back to Map", "")
            .replace("reflect the following tournaments", "")
        )
        l = re.sub(r"\s+", " ", l)
        if l in ("", " "):
            continue
        nl.append(l)

    # Convert the division info to a structure
    info = []
    curinfo = {}
    for l in nl:
        if l.startswith("DIVISION"):
            div_parts = l.strip().split()
            curinfo = {
                "code": div_parts[1],
                "division": " ".join(div_parts[2:]),
                "region": region,
                "other_header": [],
                "places": [],
            }
            info.append(curinfo)
        elif re.match(r"\s*[a-zA-Z]", l):
            if curinfo:
                curinfo["other_header"].append(l)
        elif re.match(r"\s*[0-9]+ .*" + args.search, l, flags=re.IGNORECASE):
            if curinfo:
                place_info = l.split("|")
                curinfo["places"].append(
                    {
                        "place": int(place_info[0]),
                        "name": fix_html(get_random_name(args, place_info[1].strip())),
                        "points": int(place_info[2].strip()),
                        "location": fix_html(place_info[3].strip()),
                    }
                )
    return info


def renumber_places(places):
    """Given an array of places, sorted by score, change the "place" value to match the order"""
    last_place = 0
    last_score = 0
    index = 0
    for p in places:
        index += 1
        if p["points"] != last_score:
            last_place = index
        p["place"] = last_place
        last_score = p["points"]


def trim_info(args, info, place_only=False):
    """
    Apply the --search and --maximum-place criteria against the info array.
    """
    for i in info:
        new_places = []
        if not place_only:
            if args.competition:
                ldivision = i["division"].lower()
                found_competition = False
                for competition in args.competition:
                    if ldivision.startswith(COMPETITIONS[competition]):
                        found_competition = True
                        break
                if not found_competition:
                    # get rid of this one right now
                    i["places"] = []

            if args.keep_division_if:
                keep_division = False
                for j in i["places"]:
                    for k in args.keep_division_if:
                        if k.lower() in j["name"].lower() or k.lower() in j["location"].lower():
                            keep_division = True
                            break
                if not keep_division:
                    # get rid of this one right now
                    i["places"] = []

        for j in i["places"]:
            keep = True
            if j["place"] > args.maximum_place:
                keep = False
            if args.search and not place_only:
                if args.search.lower() not in j["name"].lower() and args.search.lower() not in j["location"].lower():
                    keep = False

            if keep:
                new_places.append(j)
        i["places"] = new_places

    new_info = []
    for i in info:
        if i["places"]:
            new_info.append(i)
    return new_info


def info_by_name(info):
    """given a structure'd set of standings, print it by division"""
    # {
    #    sortable_name => { "name": str, "location": str,
    #              "divisions": [
    #                  { "region": str, "division": str, "code": str, "place": int, "points": int }, ...
    #              ]}
    name_info = {}
    for i in info:
        for j in i["places"]:
            sname = sortable_name(j["name"])
            if sname not in name_info:
                name_info[sname] = {"name": j["name"], "divisions": [], "location": j["location"]}
            name_info[sname]["divisions"].append(
                {
                    "region": i["region"],
                    "division": i["division"],
                    "code": i["code"],
                    "place": j["place"],
                    "points": j["points"],
                }
            )

    return name_info


def omitted(args, nm, s):
    """
    Check if nm is in the args.omit list.
    If not, print the string s without a line ending.
    If so, return an empty string.
    """
    return s if not args.omit or nm not in args.omit else ""  # if nm in args.omit else s


def print_omitted(args, nm, s):
    """
    Check if nm is in the args.omit list.
    If not, print the string s without a line ending.
    """
    print(omitted(args, nm, s), end="")


def sortable_name(nm):
    """
    Return a name as LAST, FIRST.
    Suffixes "jr.", "sr.", "i", "ii", "iii" and "iv" are considered part of the last name
    Prefixes "van", "san", "de", "da", "los" "st.", "saint" are considered part of the last name
    """
    nm_parts = nm.lower().split()
    end = len(nm_parts)
    if nm_parts[end - 1] in NAME_SUFFIXES:
        end -= 1
    while end > 2 and nm_parts[end - 2] in NAME_PREFIXES:
        end -= 1
    return " ".join(nm_parts[end - 1 :]) + ", " + " ".join(nm_parts[0 : end - 1])


def print_info_by_name(args, info):
    """given a structure'd set of standings, print it by name"""
    name_info = info_by_name(info)
    for name in sorted(name_info.keys()):
        val = name_info[name]
        print_omitted(args, "name", val["name"])
        print_omitted(args, "location", f' {val["location"]}')
        if args.by_person_with_divisions:
            for div in val["divisions"]:
                print(" |", end="")
                print_omitted(args, "region", f' {div["region"]}')
                print_omitted(args, "place", f' {div["place"]}')
                print_omitted(args, "code", f' {div["code"]}')
                print_omitted(args, "division", f' {div["division"]}')
                print_omitted(args, "points", f' {div["points"]}')
        print("")


def print_info_by_division(args, info):
    """Given a structure'd set of standings, print it by division"""
    for i in info:
        print(f"DIVISION", end="")
        print_omitted(args, "region", f' {i["region"]}')
        print_omitted(args, "code", f' {i["code"]}')
        print_omitted(args, "division", f' {i["division"]}')
        print("")

        print_omitted(args, "place", " Place")
        print_omitted(args, "name", " Name")
        print_omitted(args, "points", " Pts")
        print_omitted(args, "location", " Location")
        print("")

        for j in i["places"]:
            print_omitted(args, "place", f' {j["place"]}')
            print_omitted(args, "name", f' {j["name"]}')
            print_omitted(args, "points", f' {j["points"]}')
            print_omitted(args, "location", f' {j["location"]}')
            print("")


def print_info(args, info):
    """Given a structure'd set of standings, print it appropriately"""
    if args.dots:
        print("", file=sys.stderr)
    if args.by_person or args.by_person_with_divisions:
        print_info_by_name(args, info)
    else:
        print_info_by_division(args, info)


def print_worlds(args):
    """Print the worlds standings"""
    if args.division_code:
        codes = [[f"code={code}", ""] for code in args.division_code]
    else:
        codes = get_codes(args, WORLDBASE)

    if args.list_division_codes:
        print("WORLD STANDINGS DIVISIONS")
        for code in codes:
            print(f"{code[0].split('=')[1]}: {code[1]}")

    else:
        print(f"WORLD STANDINGS", end="")
        if args.search:
            print(f", searching for '{args.search}'", end="")
        print(f", maximum place of {args.maximum_place}")

        all_info = []
        for code in codes:
            info = get_info(args, code, "WORLDS", f"{WORLDBASE}?{code[0]}", "INFO")
            all_info += info
        all_info = trim_info(args, all_info)
        print_info(args, all_info)


def get_country(state):
    """Return the appropriate country for a given state"""
    # https://atamartialarts.com/Scripts/state-standing.bundle.js
    # Set the country code appropriately based on the state.
    # Experimentally, it looks like "country=$COUNTRY" is NOT required,
    # but we'll pass it in anyway.
    if state in ["AB", "BC", "MB", "NB", "NL", "NS", "NT", "NU", "ON", "PE", "QC", "SK", "YT"]:
        country = "CA"
    else:
        country = "US"
    return country


def print_districts(args, need_nl):
    """Print the district standings"""

    for district in args.district:
        if need_nl or district != args.district[0]:
            print("")

        if args.division_code:
            codes = [[f"code={code}", ""] for code in args.division_code]

        if args.list_division_codes:
            if not args.division_code:
                # The codes are the set of the codes from all of the states.
                # We don't use the world's set of codes because we also need
                # any color belt divisions.
                codes = []
                codeset = set()
                for state in DISTRICTS[district]:
                    country = get_country(state)
                    ncodes = get_codes(args, f"{STATEBASE}?country={country}&state={state}")
                    for x in ncodes:
                        if x[0] not in codeset:
                            codes.append(x)
                            codeset.add(x[0])

            print(f"DISTRICT STANDINGS DIVISIONS FOR {district}")
            for code in codes:
                print(f"{code[0].split('=')[1]}: {code[1]}")

        else:
            print(f"DISTRICT STANDINGS FOR {district}", end="")
            if args.search:
                print(f", searching for '{args.search}'", end="")
            print(f", maximum place of {args.maximum_place}")

            temp_maximum_place = args.maximum_place
            args.maximum_place = 10
            all_info = []
            for state in DISTRICTS[district]:
                country = get_country(state)
                if not args.division_code:
                    country = get_country(state)
                    codes = get_codes(args, f"{STATEBASE}?country={country}&state={state}")

                for code in codes:
                    info = get_info(
                        args, code, district, f"{STATEBASE}?country={country}&state={state}&{code[0]}", "CONTENT"
                    )
                    info = trim_info(args, info, place_only=True)
                    for i in info:
                        # if the corresponding i[division] is in all_info.division,
                        #     append i[places] to all_info[places]
                        # otherwise
                        #     add this entire i to all_info
                        found = False
                        for ai in all_info:
                            if i["division"] == ai["division"]:
                                found = True
                                ai["places"] += i["places"]
                                break

                        if not found:
                            all_info.append(i)

            args.maximum_place = temp_maximum_place
            # sort the places arrays
            for ai in all_info:
                ai["places"] = sorted(ai["places"], key=lambda k: (-k["points"], sortable_name(k["name"])))
                renumber_places(ai["places"])
            all_info = trim_info(args, all_info)
            print_info(args, all_info)


def print_states(args, need_nl):
    """Print the state standings"""
    # The web site allows for both lower and upper case. Upper case displays better.
    for i in range(len(args.state)):
        args.state[i] = args.state[i].upper()

    for state in args.state:
        if need_nl or state != args.state[0]:
            print("")

        country = get_country(state)

        if args.division_code:
            codes = [[f"code={code}", ""] for code in args.division_code]
        else:
            codes = get_codes(args, f"{STATEBASE}?country={country}&state={state}")

        if args.list_division_codes:
            print(f"STATE STANDINGS DIVISIONS FOR {state}")
            for code in codes:
                print(f"{code[0].split('=')[1]}: {code[1]}")

        else:
            print(f"STATE STANDINGS FOR {state}", end="")
            if args.search:
                print(f", searching for '{args.search}'", end="")
            print(f", maximum place of {args.maximum_place}")

            all_info = []
            for code in codes:
                info = get_info(args, code, state, f"{STATEBASE}?country={country}&state={state}&{code[0]}", "CONTENT")
                all_info += info
            all_info = trim_info(args, all_info)
            print_info(args, all_info)


def check_option(arglist, opts, choices):
    """check the values in the arglist against a list of choices"""
    if arglist:
        for arg in arglist:
            if arg not in choices:
                sys.exit(f"{sys.argv[0]}: error: argument {opts}: invalid choice: '{arg}' (choose from " f"{choices})")


def print_readme_heading():
    """Print the opening of the readme file."""
    # pylint: disable=line-too-long,bad-continuation
    print(
        """
	# ATA (American Taekwondo Association) World and State Standings Printer

	The American Taekwondo Association's tournament series has its results online.
	However, the user interface is oriented towards looking at a division at a time
	and has no provisions for searching based on a person's name or school.

	# atastandings Options

	All `atastandings` options are specified using two hyphens (`--`) and the option name,
	possibly followed by an argument such as a search string or a state/province abbreviation.
	There are also short versions of most of the options that are a single hyphen and a single lettter.

	## Worlds, District and State Standings
	The default for `atastandings` is to search the world standings.
	You can instead ask it to search one or more state or district standings.

	* `--worlds`, `-W` -- search the world standings.
	* `--district name`, `-d name` -- search the given district, one of
	`Mid-America`,
	`Midwest`,
	`Northeast`,
	`Northwest`,
	`Rockies`,
	`Southeast`,
	`South`,
	or `Southwest`.
	This may be specified multiple times.
	* `--state ABBREV`, `-S ABBREV` -- search the given state or province, using the two character state or province postoffice code.
	This may be specified multiple times.

	For example, both `atastandings` and  `atastandings --worlds` will search the world standings.
	`atastandings --district northeast` will search the Northeast district.
	`atastandings --state pa --state ca` will search the state standings for Pennsylvania and California.
	`atastandings --worlds --state ca` will search both the world stands and the state standings for California.

	## Division Control

	The default for `atastandings` is to print information for *all* divisions.
	Alternatively, you can restrict your output to specific division codes.
	For example, the division code for **1st Degree Black Belt Age 9 - 10** is *B01B*.

	To find out what the division codes are, you can get a list:

	* `--list-division-codes`, `-l` -- list all of the division codes.
	This  can be combined with  `--district name`, or `--state STATE-ABBREV` to get the division codes specific to a state/province.

	* `--division-code code`, `-c code` -- Restrict the output to the specified diision code.
	This may be specified multiple times.
	* `--competition competition` -- Only print this competition, one of
	`forms`,
	`weapons`,
	`combat-weapons`,
	`sparring`,
	`creative-forms`,
	`creative-weapons`,
	`x-treme-forms`,
	or `x-treme-weapons`.
	May be specified multiple times.

	(Not all divisions have competitors in each state or province.
	Also, color belt divisions will not show in the world standings list.)

	## Searching

	There are two types of searching available.
	* `--search string`, `-s string` -- Only print entries that have this string in either the person's name OR the school location. (Case is ignored.)
	* `--keep-division-if string`, `-k string` -- Only print a division if the string is found in any of the people's names or school locations in the division.

	## Place Standings

	The default for `atastandings` is to print all current place standings in each division.
	The place standings for each state on the web site show the top 10 people, but you might only
	be interested in who the first place leaders are.

	* `--maximum-place MAXIMUM-PLACE`, `-p MAXIMUM-PLACE` -- limit the output to only those whose place is less than or equal to the specified maximum place.

	For example, `--maximum-place 1` would print only the first place leaders,
	and `--maximum-place 4` will print only the top four contenders.

	## By Person Printing (Champion Status)
	Normally, `atastandings` prints the results arranged by division.
	You might prefer the printout to be arranged by an individual's name instead, with or without the division information.
	The names are printed in order, sorted by last name.
	(Suffixes like "Jr." and prefixes like "van" are taken into consideration in the sorting process.)

	* `--by-person`, `-b` -- Print the names and location of each individual.
	* `--by-person-with-divisions`, `-B` -- Print the names and location of each individual, followed by a list of their divisions.

	## Omitting Information
	Normally, `atastandings` will print all information, including such things as the location, place and points.
	You can choose to omit pieces of information.

	* `--omit item`, `-O item` -- Omit information from the printouts,
	where `item` is one of `location`, `place`, `points`, `region`, `division` or `code`.
	The `region` is either the world "WORLDS" or the state or province name.
	The code is the division code.
	This may be specified multiple times.

	## Web Cache
	By default, `atastandings` will maintain a cache of the web sites, so that you can have faster response times
	when you run the program multiple times.
	Most of the time you can ignore that the cache is being used, as cache files older than 24 hours are automatically ignored.
	However power users might want additional controls.

	* `--cache-directory PATH`, `-C PATH` -- This will set the cache directory to the given path.
	It defaults to an os-specific temp directory.
	* `--clean-cache` -- Sometimes you might wish to clean up all of the cached files.
	All cache files are named `atastandings.` followed by a long string of characters representing the web file being referenced.
	* `--ignore-existing-cache`, `-I` -- Sometimes you might want the existing cache to be ignored, but still created.
	Doing this will give you slower response times.
	* `--ignore-cache-times`, `-T` -- Sometimes you want to ignore that the fact that the cache file is older than 24 hours.
	* `--do-not-write-cache`, `-D` -- Sometimes you might want the cache files to not be written.
	For example, you can use use this option if there are problems on your system with the cache directory.
	Doing this will give you slower response times when you run the program again.


	## Getting Help and Miscellaneous Other Options

	* `--dots`, `-.` -- Dots will be printed for each file that is being retrieved from the web or the cache.

	Finally, you can ask for help on what options are available:

	* `--help`, `-h` -- Show a help message listing all of the options and variations.


	# Sample Use Examples

	The following examples show some of the ways that the various options can be combined together.
	All sample output uses fictitious names, and only shows the first 10 lines of the output.

	""".replace(
            "\t", ""
        )[
            1:
        ]
    )
    # pylint: enable=line-too-long,bad-continuation


def print_readme_trailer():
    """Print the trailer of the readme file."""
    # pylint: disable=line-too-long,bad-continuation
    print(
        """
# Installation
This program was written using python3, so you will need a python3 environment to run it.
You will also need the python `requests` library.
(In my opinion, if you have a Windows system, the easiest way to install a full python3
environment is to install the MicroSoft WSL2 infrastructure, which will include python3
and many other tools.)

If you do not have the `requests` library, you will need to run a command such as this to load it:
``` shell
pip3 install requests
```

Put the atastandings script somewhere in your path, make sure it is executable
(in Linux and WSL, `chmod a+x atastandings`) and run it with the options you desire.
Or you can invoke the script directly with python3, as in `python3 atastandings` followed
by the options you desire.
You might need to execute it as `./atastandings` followed by the options you desire.
	""".replace(
            "\t", ""
        )[
            1:
        ]
    )
    # pylint: enable=line-too-long,bad-continuation


def start_readme(args):
    """
    Print the preamble of a readme segment, and set up capturing the output.
    If also printing a maximum # of lines, redirect stdout and
    return the old sys.stdout
    """
    print(f"## `{args.generate_readme}`")
    print(f"`{os.path.basename(sys.argv[0])}", end="")
    sa1 = [item for sa in SUPPRESSED_ARGUMENTS for item in sa]

    skip = False
    for arg in sys.argv[1:]:
        if skip:
            skip = False
        elif arg in sa1:
            skip = True
        elif " " in arg:
            print(f' "{arg}"', end="")
        else:
            print(f" {arg}", end="")

    print("`")
    if args.readme_explanation:
        print("")
        print(args.readme_explanation)
    print("")
    print("``` shell")
    if args.maximum_lines:
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        return old_stdout
    return None


def stop_readme(args, old_stdout):
    """
    Print the postamble of a readme. If the output had a maximum # of lines,
    restore stdout and print those lines.
    """
    if args.maximum_lines:
        sio = sys.stdout
        sys.stdout = old_stdout
        ml = int(args.maximum_lines)
        for i, ln in enumerate(sio.getvalue().splitlines()):
            if i < ml:
                print(ln)
            elif i == ml:
                print(". . .")
            else:
                break
    print("```")
    print("")


def parse_options():
    """Set up all of the option parsing"""
    parser = argparse.ArgumentParser(description=__doc__, epilog=EPILOG)
    grp_search = parser.add_argument_group("Search Options")
    grp_search.add_argument("-W", "--worlds", help="Search the world standings.", action="store_true")
    grp_search.add_argument(
        "-S", "--state", help="State to search. May be specified multiple times.", type=str, action="append"
    )
    grp_search.add_argument(
        "-d", "--district", help="District to search. May be specified multiple times.", type=str, action="append"
    )
    grp_search.add_argument("-s", "--search", help="String to search for in the standings.", type=str, default="")
    grp_search.add_argument(
        "-k",
        "--keep-division-if",
        help="Keep division if this string is found in the standings. May be specified multiple times.",
        type=str,
        action="append",
    )
    grp_search.add_argument(
        "-p",
        "--maximum-place",
        help="Only print places with a number <= than this. (e.g. 1 means 1st place) Default: all",
        type=int,
        default=99,
    )
    grp_search.add_argument(
        "-c",
        "--division-code",
        help="Only print this division. May be specified multiple times.",
        type=str,
        action="append",
    )
    grp_search.add_argument(
        "--competition",
        help=f"Only print this competition, one of {COMPETITIONS}. May be specified multiple times.",
        type=str,
        action="append",
    )

    grp_output = parser.add_argument_group("Output Options")
    grp_output.add_argument("-b", "--by-person", help="Print the standings by name", action="store_true")
    grp_output.add_argument("-B", "--by-person-with-divisions", help="Print the standings by name", action="store_true")
    grp_output.add_argument(
        "-O", "--omit", help="Item to skip printing. May be specified multiple times.", type=str, action="append"
    )
    grp_search.add_argument(
        "-l", "--list-division-codes", help="List the division codes instead of printing standings", action="store_true"
    )

    grp_cache = parser.add_argument_group("Cache Control Options")
    grp_cache.add_argument(
        "-C",
        "--cache-directory",
        help="Keep a cache of the web pages in this directory.",
        type=str,
        default=get_cache_dir(),
    )
    grp_cache.add_argument(
        "-I",
        "--ignore-existing-cache",
        help="Ignore any existing cache of the web pages. (Still create one though.)",
        action="store_true",
    )
    grp_cache.add_argument(
        "-T", "--ignore-cache-times", help="Do not timeout any existing cache of the web pages.", action="store_true"
    )
    grp_cache.add_argument(
        "-D", "--do-not-write-cache", help="Do not write a cache of the web pages.", action="store_true"
    )
    grp_cache.add_argument(
        "--clean-cache", help="Remove all of the files in the current cache of the web pages.", action="store_true"
    )

    grp_other = parser.add_argument_group("Other Options")
    grp_other.add_argument(
        "-v",
        "--verbose",
        help="Verbose, print some debugging information. May be specified multiple times for higher verbosity levels.",
        action="count",
        default=0,
    )
    grp_other.add_argument("--dots", help="Print a dot for each web page accessed.", action="store_true")

    for a, arg, has_option in SUPPRESSED_ARGUMENTS:
        if has_option:
            grp_other.add_argument(a, arg, help=argparse.SUPPRESS, type=str)
        else:
            grp_other.add_argument(a, arg, help=argparse.SUPPRESS, action="store_true")
    return parser.parse_args()


def mixin_configuration(args):
    """
    Look for a configuration file and mix its values in
    with the command line.
    Look for the first of:
        ~/.atastandings.yaml
        dirname($0)/.atastandings.yaml
    """
    yaml_name = ".atastandings.yaml"
    conf_args = {}
    for conf in [
        os.getenv("HOME", "/does-not-exist/") + "/" + yaml_name,
        os.path.dirname(os.path.realpath(__file__)) + "/" + yaml_name,
    ]:
        print(f"looking for {conf}")
        try:
            with open(conf) as fp:
                conf_args = yaml.safe_load(fp)
            print(f"conf_args={conf_args}")
            args_dict = vars(args)
            print(f"args_dict={args_dict}")
            for k, v in conf_args.items():
                if k not in args_dict:
                    print(f"args.{k} <= {v}")
                    setattr(args, k, v)
                    print(f"args.verbose={args.verbose}")
            break
        except yaml.YAMLError as e:
            print(f"Error parsing {conf}: {e}")
        except FileNotFoundError as e:
            pass  # go to the next one

    return args


def main():
    """main function"""
    args = parse_options()
    args = mixin_configuration(args)
    print(f"verbose={args.verbose}")
    sys.exit()

    # check the values of the --omit option
    check_option(args.omit, "-O/--omit", OMIT_CHOICES)
    # check the values of the --district option
    if args.district:
        # Re-capitalize the district names
        for i in range(len(args.district)):
            args.district[i] = "-".join([x.capitalize() for x in args.district[i].split("-")])
        check_option(args.district, "-d/--district", DISTRICTS.keys())
    # check the values of the --competition option
    check_option(args.competition, "--competiton", COMPETITIONS.keys())

    if args.output:
        sys.stdout = open(args.output, "a")

    if args.print_readme_heading:
        print_readme_heading()
        sys.exit()

    if args.print_readme_trailer:
        print_readme_trailer()
        sys.exit()

    if args.generate_readme:
        old_stdout = start_readme(args)

    if args.clean_cache:
        clean_cache(args)

    if not args.worlds and not args.district and not args.state:
        args.worlds = True

    try:
        if args.worlds:
            print_worlds(args)

        if args.district:
            print_districts(args, args.worlds)

        if args.state:
            print_states(args, args.worlds or args.district)
    except BrokenPipeError:
        pass

    if args.generate_readme:
        stop_readme(args, old_stdout)


if __name__ == "__main__":
    main()
