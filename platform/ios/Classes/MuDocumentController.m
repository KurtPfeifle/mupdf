//
//  MuDocumentController.m
//  MuPDF
//
//  Copyright (c) 2013 Artifex Software, Inc. All rights reserved.
//

#include "common.h"
#import "MuPageView.h"

#import "MuDocumentController.h"

#define GAP 20
#define INDICATOR_Y -44-24
#define SLIDER_W (width - GAP - 24)
#define SEARCH_W (width - GAP - 170)

static void flattenOutline(NSMutableArray *titles, NSMutableArray *pages, fz_outline *outline, int level)
{
	char indent[8*4+1];
	if (level > 8)
		level = 8;
	memset(indent, ' ', level * 4);
	indent[level * 4] = 0;
	while (outline)
	{
		if (outline->dest.kind == FZ_LINK_GOTO)
		{
			int page = outline->dest.ld.gotor.page;
			if (page >= 0 && outline->title)
			{
				NSString *title = [NSString stringWithUTF8String: outline->title];
				[titles addObject: [NSString stringWithFormat: @"%s%@", indent, title]];
				[pages addObject: [NSNumber numberWithInt: page]];
			}
		}
		flattenOutline(titles, pages, outline->down, level + 1);
		outline = outline->next;
	}
}

@implementation MuDocumentController

- (id) initWithFilename: (NSString*)filename document: (MuDocRef *)aDoc
{
	self = [super init];
	if (!self)
		return nil;

	key = [filename retain];
	docRef = [aDoc retain];
	doc = docRef->doc;

	dispatch_sync(queue, ^{});

	fz_outline *root = fz_load_outline(doc);
	if (root) {
		NSMutableArray *titles = [[NSMutableArray alloc] init];
		NSMutableArray *pages = [[NSMutableArray alloc] init];
		flattenOutline(titles, pages, root, 0);
		if ([titles count])
			outline = [[MuOutlineController alloc] initWithTarget: self titles: titles pages: pages];
		[titles release];
		[pages release];
		fz_free_outline(ctx, root);
	}

	return self;
}

- (void) loadView
{
	[[NSUserDefaults standardUserDefaults] setObject: key forKey: @"OpenDocumentKey"];

	current = [[NSUserDefaults standardUserDefaults] integerForKey: key];
	if (current < 0 || current >= fz_count_pages(doc))
		current = 0;

	UIView *view = [[UIView alloc] initWithFrame: CGRectZero];
	[view setAutoresizingMask: UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[view setAutoresizesSubviews: YES];

	canvas = [[UIScrollView alloc] initWithFrame: CGRectMake(0,0,GAP,0)];
	[canvas setAutoresizingMask: UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[canvas setPagingEnabled: YES];
	[canvas setShowsHorizontalScrollIndicator: NO];
	[canvas setShowsVerticalScrollIndicator: NO];
	[canvas setDelegate: self];

	[canvas addGestureRecognizer: [[[UITapGestureRecognizer alloc] initWithTarget: self action: @selector(onTap:)] autorelease]];

	scroll_animating = NO;

	indicator = [[UILabel alloc] initWithFrame: CGRectZero];
	[indicator setAutoresizingMask: UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin];
	[indicator setText: @"0000 of 9999"];
	[indicator sizeToFit];
	[indicator setCenter: CGPointMake(0, INDICATOR_Y)];
	[indicator setTextAlignment: UITextAlignmentCenter];
	[indicator setBackgroundColor: [[UIColor blackColor] colorWithAlphaComponent: 0.5]];
	[indicator setTextColor: [UIColor whiteColor]];

	[view addSubview: canvas];
	[view addSubview: indicator];

	slider = [[UISlider alloc] initWithFrame: CGRectZero];
	[slider setMinimumValue: 0];
	[slider setMaximumValue: fz_count_pages(doc) - 1];
	[slider addTarget: self action: @selector(onSlide:) forControlEvents: UIControlEventValueChanged];

	sliderWrapper = [[UIBarButtonItem alloc] initWithCustomView: slider];

	[self setToolbarItems: [NSArray arrayWithObjects: sliderWrapper, nil]];

	// Set up the buttons on the navigation and search bar

	if (outline) {
		outlineButton = [[UIBarButtonItem alloc]
			initWithBarButtonSystemItem: UIBarButtonSystemItemBookmarks
			target:self action:@selector(onShowOutline:)];
	}
	linkButton = [[UIBarButtonItem alloc]
		initWithBarButtonSystemItem: UIBarButtonSystemItemAction
		target:self action:@selector(onToggleLinks:)];
	cancelButton = [[UIBarButtonItem alloc]
		initWithTitle: @"Cancel" style: UIBarButtonItemStyleBordered
		target:self action:@selector(onCancelSearch:)];
	searchButton = [[UIBarButtonItem alloc]
		initWithBarButtonSystemItem: UIBarButtonSystemItemSearch
		target:self action:@selector(onShowSearch:)];
	prevButton = [[UIBarButtonItem alloc]
		initWithBarButtonSystemItem: UIBarButtonSystemItemRewind
		target:self action:@selector(onSearchPrev:)];
	nextButton = [[UIBarButtonItem alloc]
		initWithBarButtonSystemItem: UIBarButtonSystemItemFastForward
		target:self action:@selector(onSearchNext:)];

	searchBar = [[UISearchBar alloc] initWithFrame: CGRectMake(0,0,50,32)];
	[searchBar setPlaceholder: @"Search"];
	[searchBar setDelegate: self];
	// HACK to make transparent background
	[[searchBar.subviews objectAtIndex:0] removeFromSuperview];

	[prevButton setEnabled: NO];
	[nextButton setEnabled: NO];

	[[self navigationItem] setRightBarButtonItems:
		[NSArray arrayWithObjects: searchButton, linkButton, outlineButton, nil]];

	// TODO: add activityindicator to search bar

	[self setView: view];
	[view release];
}

- (void) dealloc
{
	[docRef release]; docRef = nil; doc = NULL;
	[indicator release]; indicator = nil;
	[slider release]; slider = nil;
	[sliderWrapper release]; sliderWrapper = nil;
	[searchBar release]; searchBar = nil;
	[outlineButton release]; outlineButton = nil;
	[searchButton release]; searchButton = nil;
	[cancelButton release]; cancelButton = nil;
	[prevButton release]; prevButton = nil;
	[nextButton release]; nextButton = nil;
	[canvas release]; canvas = nil;

	[outline release];
	[key release];
	[super dealloc];
}

- (void) viewWillAppear: (BOOL)animated
{
	[self setTitle: [key lastPathComponent]];

	[slider setValue: current];

	[indicator setText: [NSString stringWithFormat: @" %d of %d ", current+1, fz_count_pages(doc)]];

	[[self navigationController] setToolbarHidden: NO animated: animated];
}

- (void) viewWillLayoutSubviews
{
	CGSize size = [canvas frame].size;
	int max_width = fz_max(width, size.width);

	width = size.width;
	height = size.height;

	[canvas setContentInset: UIEdgeInsetsZero];
	[canvas setContentSize: CGSizeMake(fz_count_pages(doc) * width, height)];
	[canvas setContentOffset: CGPointMake(current * width, 0)];

	[sliderWrapper setWidth: SLIDER_W];
	[searchBar setFrame: CGRectMake(0,0,SEARCH_W,32)];

	[[[self navigationController] toolbar] setNeedsLayout]; // force layout!

	// use max_width so we don't clamp the content offset too early during animation
	[canvas setContentSize: CGSizeMake(fz_count_pages(doc) * max_width, height)];
	[canvas setContentOffset: CGPointMake(current * width, 0)];

	for (MuPageView *view in [canvas subviews]) {
		if ([view number] == current) {
			[view setFrame: CGRectMake([view number] * width, 0, width-GAP, height)];
			[view willRotate];
		}
	}
	for (MuPageView *view in [canvas subviews]) {
		if ([view number] != current) {
			[view setFrame: CGRectMake([view number] * width, 0, width-GAP, height)];
			[view willRotate];
		}
	}
}

- (void) viewDidAppear: (BOOL)animated
{
	[self scrollViewDidScroll: canvas];
}

- (void) viewWillDisappear: (BOOL)animated
{
	[self setTitle: @"Resume"];
	[[NSUserDefaults standardUserDefaults] removeObjectForKey: @"OpenDocumentKey"];
	[[self navigationController] setToolbarHidden: YES animated: animated];
}

- (void) showNavigationBar
{
	if ([[self navigationController] isNavigationBarHidden]) {
		[[self navigationController] setNavigationBarHidden: NO];
		[[self navigationController] setToolbarHidden: NO];
		[indicator setHidden: NO];

		[UIView beginAnimations: @"MuNavBar" context: NULL];

		[[[self navigationController] navigationBar] setAlpha: 1];
		[[[self navigationController] toolbar] setAlpha: 1];
		[indicator setAlpha: 1];

		[UIView commitAnimations];
	}
}

- (void) hideNavigationBar
{
	if (![[self navigationController] isNavigationBarHidden]) {
		[searchBar resignFirstResponder];

		[UIView beginAnimations: @"MuNavBar" context: NULL];
		[UIView setAnimationDelegate: self];
		[UIView setAnimationDidStopSelector: @selector(onHideNavigationBarFinished)];

		[[[self navigationController] navigationBar] setAlpha: 0];
		[[[self navigationController] toolbar] setAlpha: 0];
		[indicator setAlpha: 0];

		[UIView commitAnimations];
	}
}

- (void) onHideNavigationBarFinished
{
	[[self navigationController] setNavigationBarHidden: YES];
	[[self navigationController] setToolbarHidden: YES];
	[indicator setHidden: YES];
}

- (void) onShowOutline: (id)sender
{
	[[self navigationController] pushViewController: outline animated: YES];
}

- (void) onToggleLinks: (id)sender
{
	showLinks = !showLinks;
 	for (MuPageView *view in [canvas subviews])
	{
		if (showLinks)
			[view showLinks];
		else
			[view hideLinks];
	}
}

- (void) onShowSearch: (id)sender
{
	[[self navigationItem] setTitleView: searchBar];
	[[self navigationItem] setRightBarButtonItems:
		[NSArray arrayWithObjects: nextButton, prevButton, nil]];
	[[self navigationItem] setLeftBarButtonItem: cancelButton];
	[searchBar becomeFirstResponder];
}

- (void) onCancelSearch: (id)sender
{
	cancelSearch = YES;
	[searchBar resignFirstResponder];
	[[self navigationItem] setTitleView: nil];
	[[self navigationItem] setRightBarButtonItems:
		[NSArray arrayWithObjects: searchButton, linkButton, outlineButton, nil]];
	[[self navigationItem] setLeftBarButtonItem: nil];
	[self resetSearch];
}

- (void) resetSearch
{
	searchPage = -1;
	for (MuPageView *view in [canvas subviews])
		[view clearSearchResults];
}

- (void) showSearchResults: (int)count forPage: (int)number
{
	printf("search found match on page %d\n", number);
	searchPage = number;
	[self gotoPage: number animated: NO];
	for (MuPageView *view in [canvas subviews])
		if ([view number] == number)
			[view showSearchResults: count];
		else
			[view clearSearchResults];
}

- (void) searchInDirection: (int)dir
{
	UITextField *searchField;
	char *needle;
	int start;

	[searchBar resignFirstResponder];

	if (searchPage == current)
		start = current + dir;
	else
		start = current;

	needle = strdup([[searchBar text] UTF8String]);

	searchField = nil;
	for (id view in [searchBar subviews])
		if ([view isKindOfClass: [UITextField class]])
			searchField = view;

	[prevButton setEnabled: NO];
	[nextButton setEnabled: NO];
	[searchField setEnabled: NO];

	cancelSearch = NO;

	dispatch_async(queue, ^{
		for (int i = start; i >= 0 && i < fz_count_pages(doc); i += dir) {
			int n = search_page(doc, i, needle, NULL);
			if (n) {
				dispatch_async(dispatch_get_main_queue(), ^{
					[prevButton setEnabled: YES];
					[nextButton setEnabled: YES];
					[searchField setEnabled: YES];
					[self showSearchResults: n forPage: i];
					free(needle);
				});
				return;
			}
			if (cancelSearch) {
				dispatch_async(dispatch_get_main_queue(), ^{
					[prevButton setEnabled: YES];
					[nextButton setEnabled: YES];
					[searchField setEnabled: YES];
					free(needle);
				});
				return;
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			printf("no search results found\n");
			[prevButton setEnabled: YES];
			[nextButton setEnabled: YES];
			[searchField setEnabled: YES];
			UIAlertView *alert = [[UIAlertView alloc]
				initWithTitle: @"No matches found for:"
				message: [NSString stringWithUTF8String: needle]
				delegate: nil
				cancelButtonTitle: @"Close"
				otherButtonTitles: nil];
			[alert show];
			[alert release];
			free(needle);
		});
	});
}

- (void) onSearchPrev: (id)sender
{
	[self searchInDirection: -1];
}

- (void) onSearchNext: (id)sender
{
	[self searchInDirection: 1];
}

- (void) searchBarSearchButtonClicked: (UISearchBar*)sender
{
	[self onSearchNext: sender];
}

- (void) searchBar: (UISearchBar*)sender textDidChange: (NSString*)searchText
{
	[self resetSearch];
	if ([[searchBar text] length] > 0) {
		[prevButton setEnabled: YES];
		[nextButton setEnabled: YES];
	} else {
		[prevButton setEnabled: NO];
		[nextButton setEnabled: NO];
	}
}

- (void) onSlide: (id)sender
{
	int number = [slider value];
	if ([slider isTracking])
		[indicator setText: [NSString stringWithFormat: @" %d of %d ", number+1, fz_count_pages(doc)]];
	else
		[self gotoPage: number animated: NO];
}

- (void) onTap: (UITapGestureRecognizer*)sender
{
	CGPoint p = [sender locationInView: canvas];
	CGPoint ofs = [canvas contentOffset];
	float x0 = (width - GAP) / 5;
	float x1 = (width - GAP) - x0;
	p.x -= ofs.x;
	p.y -= ofs.y;
	if (p.x < x0) {
		[self gotoPage: current-1 animated: YES];
	} else if (p.x > x1) {
		[self gotoPage: current+1 animated: YES];
	} else {
		if ([[self navigationController] isNavigationBarHidden])
			[self showNavigationBar];
		else
			[self hideNavigationBar];
	}
}

- (void) scrollViewWillBeginDragging: (UIScrollView *)scrollView
{
	[self hideNavigationBar];
}

- (void) scrollViewDidScroll: (UIScrollView*)scrollview
{
	if (width == 0)
		return; // not visible yet

	if (scroll_animating)
		return; // don't mess with layout during animations

	float x = [canvas contentOffset].x + width * 0.5f;
	current = x / width;

	[[NSUserDefaults standardUserDefaults] setInteger: current forKey: key];

	[indicator setText: [NSString stringWithFormat: @" %d of %d ", current+1, fz_count_pages(doc)]];
	[slider setValue: current];

	// swap the distant page views out

	NSMutableSet *invisiblePages = [[NSMutableSet alloc] init];
	for (MuPageView *view in [canvas subviews]) {
		if ([view number] != current)
			[view resetZoomAnimated: YES];
		if ([view number] < current - 2 || [view number] > current + 2)
			[invisiblePages addObject: view];
	}
	for (MuPageView *view in invisiblePages)
		[view removeFromSuperview];
	[invisiblePages release]; // don't bother recycling them...

	[self createPageView: current];
	[self createPageView: current - 1];
	[self createPageView: current + 1];

	// reset search results when page has flipped
	if (current != searchPage)
		[self resetSearch];
}

- (void) createPageView: (int)number
{
	if (number < 0 || number >= fz_count_pages(doc))
		return;
	int found = 0;
	for (MuPageView *view in [canvas subviews])
		if ([view number] == number)
			found = 1;
	if (!found) {
		MuPageView *view = [[MuPageView alloc] initWithFrame: CGRectMake(number * width, 0, width-GAP, height) document: docRef page: number];
		[canvas addSubview: view];
		if (showLinks)
			[view showLinks];
		[view release];
	}
}

- (void) gotoPage: (int)number animated: (BOOL)animated
{
	if (number < 0)
		number = 0;
	if (number >= fz_count_pages(doc))
		number = fz_count_pages(doc) - 1;
	if (current == number)
		return;
	if (animated) {
		// setContentOffset:animated: does not use the normal animation
		// framework. It also doesn't play nice with the tap gesture
		// recognizer. So we do our own page flipping animation here.
		// We must set the scroll_animating flag so that we don't create
		// or remove subviews until after the animation, or they'll
		// swoop in from origo during the animation.

		scroll_animating = YES;
		[UIView beginAnimations: @"MuScroll" context: NULL];
		[UIView setAnimationDuration: 0.4];
		[UIView setAnimationBeginsFromCurrentState: YES];
		[UIView setAnimationDelegate: self];
		[UIView setAnimationDidStopSelector: @selector(onGotoPageFinished)];

		for (MuPageView *view in [canvas subviews])
			[view resetZoomAnimated: NO];

		[canvas setContentOffset: CGPointMake(number * width, 0)];
		[slider setValue: number];
		[indicator setText: [NSString stringWithFormat: @" %d of %d ", number+1, fz_count_pages(doc)]];

		[UIView commitAnimations];
	} else {
		for (MuPageView *view in [canvas subviews])
			[view resetZoomAnimated: NO];
		[canvas setContentOffset: CGPointMake(number * width, 0)];
	}
	current = number;
}

- (void) onGotoPageFinished
{
	scroll_animating = NO;
	[self scrollViewDidScroll: canvas];
}

- (BOOL) shouldAutorotateToInterfaceOrientation: (UIInterfaceOrientation)o
{
	return YES;
}

- (void) didRotateFromInterfaceOrientation: (UIInterfaceOrientation)o
{
	[canvas setContentSize: CGSizeMake(fz_count_pages(doc) * width, height)];
	[canvas setContentOffset: CGPointMake(current * width, 0)];
}

@end